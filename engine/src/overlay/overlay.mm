/*
 * overlay.mm -- the in-game settings menu (overlay.h), Dear ImGui on Metal.
 *
 * The look and the controls follow SpeedBreaker's settings menu (project(u),
 * GPL-3.0-or-later): a panel over the dimmed game, a title with the shortcut,
 * page tabs, one row per option with its value between two arrows, a help
 * line, and Reset page / Close / Quit Game at the bottom. Controller first:
 * D-pad or left stick choose and change, A or Enter toggles, LB/RB (Q/E, Tab)
 * turn pages, B or Esc closes. The mouse works too.
 *
 * Main thread: overlay_event turns SDL events into menu actions and mouse
 * events, queued under a mutex. Render thread: overlay_present_metal drains
 * the queue, runs the menu, and draws it into the frame's drawable.
 */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

#include <atomic>
#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <unistd.h>

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "overlay.h"
#include "overlay_options.h"

extern "C" volatile int xbox_input_blocked;     /* xinput_device.c: the game reads a neutral pad */
extern "C" void apple_set_fullscreen(int on);   /* src/apple/apple_main.c */

namespace
{
    // ---------------------------------------------------------------- settings
    constexpr const char *kSettingsFile = "settings.ini";

    struct Opt
    {
        const OverlayOption *o;
        int cur;      // settings.ini options: the chosen value
        int launch;   // ...the one this run started with
    };
    std::vector<Opt> g_opts;
    std::vector<std::string> g_pages;
    std::mutex g_save_lock;
    int g_changed_opt = -1;     // the option changed last, and when: its help line says so for a while
    double g_changed_at;

    int Clamp(const OverlayOption *o, int c)
    {
        return c < 0 ? 0 : c >= o->n ? o->n - 1 : c;
    }

    void SettingsSave()
    {
        std::lock_guard<std::mutex> lock(g_save_lock);
        FILE *f = fopen(kSettingsFile, "w");
        if (!f) {
            fprintf(stderr, "[overlay] cannot write %s\n", kSettingsFile);
            return;
        }
        fprintf(f, "; %s: the settings menu's file (F1 or Back + Start in the game)\n", overlay_game_title());
        for (const Opt &p : g_opts)
            if (p.o->key)
                fprintf(f, "%s=%s\n", p.o->key, p.o->values[p.cur]);
        fclose(f);
    }

    int Value(const Opt &p)
    {
        if (p.o->key)
            return p.cur;
        return p.o->get ? Clamp(p.o, p.o->get()) : 0;
    }

    void SetChoice(Opt &p, int c)
    {
        if (!p.o->n)
            return;
        c = Clamp(p.o, c);
        if (p.o->key) {
            if (c == p.cur)
                return;
            p.cur = c;
            SettingsSave();
            if (p.o->apply)
                p.o->apply(c, 0);
        } else if (p.o->set && c != Value(p)) {
            p.o->set(c);
        } else
            return;
        g_changed_opt = (int)(&p - g_opts.data());
        g_changed_at = CACurrentMediaTime();
        fprintf(stderr, "[overlay] %s %s\n", p.o->label, p.o->choices[c]);
    }

    bool RestartPending(const Opt &p)
    {
        return p.o->restart && p.o->key && p.cur != p.launch;
    }

    // ---------------------------------------------------------------- state
    std::atomic<int> g_open{0};
    std::atomic<int> g_just_opened{0};
    std::atomic<int> g_closing{0};        // closed: the pad stays neutral until every button is up
    std::atomic<unsigned> g_requests{0};
    std::atomic<int> g_win_w{1}, g_win_h{1};  // the window in points (mouse coordinates)
    SDL_Window *g_window;
    bool g_inited;
    Uint32 g_init_ticks;

    // Tests: NFSU2_OVERLAY_SCRIPT="<seconds>:<action>,..." (open, close, up, down, left,
    // right, accept, back, prev, next, shot) runs menu actions at those times;
    // "shot" writes the next drawn frame to NFSU2_OVERLAY_SHOT<n>.bmp.
    struct Step { Uint32 ms; std::string act; };
    std::vector<Step> g_script;
    size_t g_script_next;
    std::atomic<int> g_shot_req{0};
    int g_shot_n;
    int g_cursor_before = -1;

    // Menu actions, from keys and controllers.
    enum Act { kUp, kDown, kLeft, kRight, kAccept, kBack, kPrev, kNext };
    struct Ev
    {
        enum Kind { kAct, kMouseMove, kMouseButton, kWheel } kind;
        int act;
        float x, y;
        int button;
        bool down;
    };
    std::mutex g_queue_lock;
    std::vector<Ev> g_queue;

    void Push(const Ev &e)
    {
        std::lock_guard<std::mutex> lock(g_queue_lock);
        if (g_queue.size() < 256)
            g_queue.push_back(e);
    }
    void PushAct(int a)
    {
        Push(Ev{ Ev::kAct, a, 0, 0, 0, false });
    }

    void Open(bool open)
    {
        if (open == (g_open.load() != 0))
            return;
        if (open) {
            xbox_input_blocked = 1;
            g_closing = 0;
            g_just_opened = 1;
            g_open = 1;
        } else {
            g_open = 0;
            g_closing = 1;      // overlay_main_tick lets the pad through once released
        }
        fprintf(stderr, "[overlay] %s\n", open ? "open" : "closed");
    }

    // Held directions repeat (D-pad, the left stick): main thread.
    struct Held
    {
        int act = -1;
        Uint32 next = 0;
    } g_held;
    int g_stick_dir = -1;   // the left stick as a D-pad: -1 centred
    int g_pad_buttons_down; // controller buttons held (events), for the release wait
    struct Chord
    {
        SDL_JoystickID id;
        bool back, start, fired;
    };
    std::vector<Chord> g_chords;

    void Hold(int act)
    {
        g_held.act = act;
        g_held.next = SDL_GetTicks() + 380;
        PushAct(act);
    }
    void Release(int act)
    {
        if (g_held.act == act)
            g_held.act = -1;
    }

    // ---------------------------------------------------------------- look
    // NFSU2's menus: a cool dark panel and the game's lime-green highlight.
    const ImVec4 kAccent(0.78f, 0.90f, 0.29f, 1.0f);
    const ImVec4 kPanel(0.055f, 0.065f, 0.085f, 0.985f);
    const ImVec4 kText(0.92f, 0.94f, 0.96f, 1.0f);
    const ImVec4 kDim(0.62f, 0.66f, 0.72f, 1.0f);
    constexpr float kFontSize = 21.0f;  // at 720 points of height

    ImU32 Col(const ImVec4 &c, float a = 1.0f)
    {
        return ImGui::GetColorU32(ImVec4(c.x, c.y, c.z, c.w * a));
    }

    // The menu's place on screen.
    struct Layout
    {
        float s;                         // 1 at 720 pixels of height
        ImVec2 p0, p1;                   // the panel
    };

    // ---------------------------------------------------------------- menu state (render thread)
    int g_page;
    int g_row;              // the chosen row of the page, -1 in the footer
    int g_footer = -1;      // 0 Reset page, 1 Close, 2 Quit Game
    int g_first;            // the first row shown (scrolling)
    bool g_quit_prompt;
    int g_quit_sel = 1;     // 0 Quit, 1 Cancel

    std::vector<int> PageRows(int page)
    {
        std::vector<int> r;
        for (int i = 0; i < (int)g_opts.size(); i++)
            if (g_pages[page] == g_opts[i].o->page)
                r.push_back(i);
        return r;
    }

    void ResetPage()
    {
        for (int i : PageRows(g_page))
            if (g_opts[i].o->n)
                SetChoice(g_opts[i], g_opts[i].o->def);
    }

    void Activate(Opt &p, int delta)
    {
        if (p.o->action) {
            if (delta == 0)
                p.o->action();
            return;
        }
        int v = Value(p);
        if (delta == 0)                       // A / Enter: the next choice, round
            SetChoice(p, (v + 1) % p.o->n);
        else
            SetChoice(p, v + delta);
    }

    void FooterButton(int i)
    {
        if (i == 0)
            ResetPage();
        else if (i == 1)
            Open(false);
        else {
            g_quit_prompt = true;
            g_quit_sel = 1;
        }
    }

    void HandleAct(int a)
    {
        std::vector<int> rows = PageRows(g_page);
        int n = (int)rows.size();
        if (g_quit_prompt) {
            if (a == kLeft || a == kRight)
                g_quit_sel ^= 1;
            else if (a == kAccept) {
                if (g_quit_sel == 0)
                    overlay_request(OVERLAY_REQ_QUIT);
                g_quit_prompt = false;
            } else if (a == kBack)
                g_quit_prompt = false;
            return;
        }
        switch (a) {
        case kPrev:
        case kNext:
            g_page = (g_page + (a == kNext ? 1 : (int)g_pages.size() - 1)) % (int)g_pages.size();
            g_row = PageRows(g_page).empty() ? -1 : 0;
            g_footer = g_row < 0 ? 1 : -1;
            g_first = 0;
            break;
        case kUp:
            if (g_footer >= 0) {
                if (n) { g_footer = -1; g_row = n - 1; }
            } else if (g_row > 0)
                g_row--;
            break;
        case kDown:
            if (g_footer < 0) {
                if (g_row < n - 1) g_row++;
                else { g_footer = 1; }
            }
            break;
        case kLeft:
        case kRight:
            if (g_footer >= 0)
                g_footer = (g_footer + (a == kRight ? 1 : 2)) % 3;
            else if (g_row >= 0 && g_row < n)
                Activate(g_opts[rows[g_row]], a == kRight ? 1 : -1);
            break;
        case kAccept:
            if (g_footer >= 0)
                FooterButton(g_footer);
            else if (g_row >= 0 && g_row < n)
                Activate(g_opts[rows[g_row]], 0);
            break;
        case kBack:
            Open(false);
            break;
        }
    }

    // A triangle pointing left (-1) or right (1), centred on c.
    void Arrow(ImDrawList *dl, ImVec2 c, float h, int dir, ImU32 col)
    {
        float w = h * 0.8f;
        if (dir < 0)
            dl->AddTriangleFilled(ImVec2(c.x - w * 0.5f, c.y), ImVec2(c.x + w * 0.5f, c.y - h * 0.5f),
                                  ImVec2(c.x + w * 0.5f, c.y + h * 0.5f), col);
        else
            dl->AddTriangleFilled(ImVec2(c.x + w * 0.5f, c.y), ImVec2(c.x - w * 0.5f, c.y - h * 0.5f),
                                  ImVec2(c.x - w * 0.5f, c.y + h * 0.5f), col);
    }

    // A clickable rectangle; true when clicked this frame.
    bool Hit(const char *id, ImVec2 a, ImVec2 b, bool *hovered = nullptr)
    {
        ImGui::SetCursorScreenPos(a);
        bool c = ImGui::InvisibleButton(id, ImVec2(b.x - a.x, b.y - a.y));
        if (hovered)
            *hovered = ImGui::IsItemHovered();
        return c;
    }

    void Text(ImDrawList *dl, ImVec2 p, float size, const ImVec4 &c, const char *t, float wrap = 0.0f)
    {
        dl->AddText(nullptr, size, p, Col(c), t, nullptr, wrap);
    }
    ImVec2 TextSize(float size, const char *t, float wrap = 0.0f)
    {
        return ImGui::GetFont()->CalcTextSizeA(size, FLT_MAX, wrap, t);
    }

    void DrawMenu(const Layout &L)
    {
        ImDrawList *dl = ImGui::GetWindowDrawList();
        const float s = L.s, fs = kFontSize * s, pad = 24 * s;
        const ImVec2 p0 = L.p0, p1 = L.p1;
        ImGuiIO &io = ImGui::GetIO();

        dl->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 150));
        dl->AddRectFilled(p0, p1, Col(kPanel), 10 * s);
        dl->AddRect(p0, p1, Col(kAccent, 0.18f), 10 * s, 0, 1.5f * s);

        // Title and shortcut
        Text(dl, ImVec2(p0.x + pad, p0.y + 18 * s), fs * 1.55f, kAccent, "Settings");
        {
            const char *hint = "F1 or Cmd+, / Back + Start";
            ImVec2 ts = TextSize(fs * 0.9f, hint);
            Text(dl, ImVec2(p1.x - pad - ts.x, p0.y + 30 * s), fs * 0.9f, kDim, hint);
        }

        // Tabs
        float x = p0.x + pad, ty = p0.y + 72 * s, th = 40 * s;
        for (int i = 0; i < (int)g_pages.size(); i++) {
            ImVec2 ts = TextSize(fs, g_pages[i].c_str());
            ImVec2 a(x, ty), b(x + ts.x + 28 * s, ty + th);
            bool hov;
            char id[32];
            snprintf(id, sizeof id, "tab%d", i);
            if (Hit(id, a, b, &hov) && !g_quit_prompt && i != g_page) {
                g_page = i;
                g_row = PageRows(i).empty() ? -1 : 0;
                g_footer = g_row < 0 ? 1 : -1;
                g_first = 0;
            }
            if (i == g_page)
                dl->AddRectFilled(a, b, Col(kAccent, 0.20f), 5 * s);
            else if (hov)
                dl->AddRectFilled(a, b, Col(kAccent, 0.08f), 5 * s);
            Text(dl, ImVec2(a.x + 14 * s, a.y + (th - fs) * 0.5f), fs, i == g_page ? kText : kDim, g_pages[i].c_str());
            x = b.x + 8 * s;
        }
        dl->AddLine(ImVec2(p0.x + pad, ty + th + 6 * s), ImVec2(p1.x - pad, ty + th + 6 * s), Col(kDim, 0.25f), s);

        // Rows
        std::vector<int> rows = PageRows(g_page);
        const float rh = 44 * s, top = ty + th + 14 * s;
        const float footer_y = p1.y - 64 * s, help_h = 104 * s;
        const bool advanced = g_pages[g_page] == "Advanced";
        const char *const *about = overlay_game_about();
        int about_lines = 0;
        if (advanced)
            while (about && about[about_lines])
                about_lines++;
        float rows_bottom = footer_y - help_h - (advanced ? about_lines * fs * 1.25f + 10 * s : 0);
        int visible = (int)((rows_bottom - top) / rh);
        if (visible < 1)
            visible = 1;
        if (g_row >= 0) {
            if (g_row < g_first)
                g_first = g_row;
            if (g_row >= g_first + visible)
                g_first = g_row - visible + 1;
        }
        const float vx1 = p1.x - pad, vx0 = vx1 - 360 * s;   // the value column
        for (int k = g_first; k < (int)rows.size() && k < g_first + visible; k++) {
            Opt &p = g_opts[rows[k]];
            float y = top + (k - g_first) * rh;
            ImVec2 a(p0.x + pad, y), b(p1.x - pad, y + rh - 4 * s);
            bool focus = g_footer < 0 && k == g_row && !g_quit_prompt, hov;
            char id[32];
            snprintf(id, sizeof id, "row%d", k);
            if (Hit(id, a, ImVec2(vx0, b.y), &hov) && !g_quit_prompt) {
                g_row = k;
                g_footer = -1;
            }
            if (focus)
                dl->AddRect(a, b, Col(kAccent), 4 * s, 0, 2 * s);
            else if (hov)
                dl->AddRectFilled(a, b, Col(kAccent, 0.06f), 4 * s);
            float cy = (a.y + b.y) * 0.5f;
            Text(dl, ImVec2(a.x + 16 * s, cy - fs * 0.5f), fs, kText, p.o->label);
            if (p.o->action) {
                const char *v = p.o->action_label ? p.o->action_label : "Open";
                ImVec2 ts = TextSize(fs, v);
                ImVec2 va((vx0 + vx1 - ts.x) * 0.5f, cy - fs * 0.5f);
                bool vh;
                snprintf(id, sizeof id, "act%d", k);
                if (Hit(id, ImVec2(vx0, a.y), ImVec2(vx1, b.y), &vh) && !g_quit_prompt) {
                    g_row = k;
                    g_footer = -1;
                    p.o->action();
                }
                Text(dl, va, fs, focus || vh ? kAccent : kText, v);
                continue;
            }
            int v = Value(p);
            const char *val = p.o->choices[v];
            ImVec2 ts = TextSize(fs, val);
            Text(dl, ImVec2((vx0 + vx1 - ts.x) * 0.5f, cy - fs * 0.5f), fs, focus ? kAccent : kText, val);
            if (RestartPending(p)) {
                const char *r = "restart";
                ImVec2 rs = TextSize(fs * 0.8f, r);
                Text(dl, ImVec2(vx0 - rs.x - 14 * s, cy - fs * 0.4f), fs * 0.8f, kAccent, r);
            }
            const float ah = 18 * s;
            ImVec2 la(vx0, a.y), lb(vx0 + 44 * s, b.y), ra(vx1 - 44 * s, a.y), rb(vx1, b.y);
            bool lh, rhv;
            snprintf(id, sizeof id, "l%d", k);
            if (Hit(id, la, lb, &lh) && !g_quit_prompt) { g_row = k; g_footer = -1; Activate(p, -1); }
            snprintf(id, sizeof id, "r%d", k);
            if (Hit(id, ra, rb, &rhv) && !g_quit_prompt) { g_row = k; g_footer = -1; Activate(p, 1); }
            Arrow(dl, ImVec2(vx0 + 22 * s, cy), ah, -1, Col(v > 0 ? (lh ? kAccent : kText) : kDim, v > 0 ? 1.0f : 0.35f));
            Arrow(dl, ImVec2(vx1 - 22 * s, cy), ah, 1, Col(v < p.o->n - 1 ? (rhv ? kAccent : kText) : kDim, v < p.o->n - 1 ? 1.0f : 0.35f));
        }
        if ((int)rows.size() > visible) {      // a scroll bar
            float h = rows_bottom - top, bh = h * visible / rows.size(), by = top + h * g_first / rows.size();
            dl->AddRectFilled(ImVec2(p1.x - pad + 6 * s, by), ImVec2(p1.x - pad + 10 * s, by + bh), Col(kDim, 0.5f), 2 * s);
        }

        // About (Advanced)
        if (advanced) {
            float y = rows_bottom + 6 * s;
            for (int i = 0; i < about_lines; i++, y += fs * 1.25f)
                Text(dl, ImVec2(p0.x + pad + 16 * s, y), fs * 0.82f, kDim, about[i]);
        }

        // Help for the chosen row
        dl->AddLine(ImVec2(p0.x + pad, footer_y - help_h + 4 * s), ImVec2(p1.x - pad, footer_y - help_h + 4 * s), Col(kDim, 0.25f), s);
        if (g_footer < 0 && g_row >= 0 && g_row < (int)rows.size()) {
            Opt &p = g_opts[rows[g_row]];
            float y = footer_y - help_h + 16 * s;
            if (p.o->help) {
                Text(dl, ImVec2(p0.x + pad, y), fs * 0.9f, kText, p.o->help, p1.x - p0.x - 2 * pad);
                y += TextSize(fs * 0.9f, p.o->help, p1.x - p0.x - 2 * pad).y + 6 * s;
            }
            const float wrap = p1.x - p0.x - 2 * pad;
            if (p.o->where) {
                std::string w = std::string("Where: ") + p.o->where;
                Text(dl, ImVec2(p0.x + pad, y), fs * 0.85f, kDim, w.c_str(), wrap);
                y += TextSize(fs * 0.85f, w.c_str(), wrap).y + 4 * s;
            }
            bool just = g_changed_opt == rows[g_row] && CACurrentMediaTime() - g_changed_at < 3.0;
            if (RestartPending(p))
                Text(dl, ImVec2(p0.x + pad, y), fs * 0.85f, kAccent, "Saved. Restart the game to apply this change.");
            else if (just)
                Text(dl, ImVec2(p0.x + pad, y), fs * 0.85f, kAccent,
                     p.o->restart ? "Saved: back to the value this run started with." : "Applied and saved.");
        }

        // Footer
        const char *labels[3] = { "Reset page", "Close", "Quit Game" };
        x = p0.x + pad;
        for (int i = 0; i < 3; i++) {
            ImVec2 ts = TextSize(fs, labels[i]);
            ImVec2 a(x, footer_y), b(x + ts.x + 32 * s, footer_y + 44 * s);
            bool hov, focus = g_footer == i && !g_quit_prompt;
            char id[16];
            snprintf(id, sizeof id, "btn%d", i);
            if (Hit(id, a, b, &hov) && !g_quit_prompt) {
                g_footer = i;
                FooterButton(i);
            }
            dl->AddRectFilled(a, b, Col(kAccent, focus ? 0.30f : hov ? 0.16f : 0.08f), 5 * s);
            if (focus)
                dl->AddRect(a, b, Col(kAccent), 5 * s, 0, 2 * s);
            Text(dl, ImVec2(a.x + 16 * s, a.y + (44 * s - fs) * 0.5f), fs, kText, labels[i]);
            x = b.x + 12 * s;
        }
        {
            const char *hint = "D-pad: choose, change   LB RB: page   A: toggle   B: close";
            ImVec2 ts = TextSize(fs * 0.85f, hint);
            Text(dl, ImVec2(p1.x - pad - ts.x, footer_y + (44 * s - fs * 0.85f) * 0.5f), fs * 0.85f, kDim, hint);
        }

        // Quit Game's prompt
        if (g_quit_prompt) {
            char q[96];
            snprintf(q, sizeof q, "Quit %s?", overlay_game_title());
            const char *sub = "Progress since your last save in the game is lost.";
            float w = 620 * s, h = 190 * s;
            ImVec2 c((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f), a(c.x - w * 0.5f, c.y - h * 0.5f), b(c.x + w * 0.5f, c.y + h * 0.5f);
            dl->AddRectFilled(p0, p1, IM_COL32(0, 0, 0, 110), 10 * s);
            dl->AddRectFilled(a, b, Col(kPanel), 10 * s);
            dl->AddRect(a, b, Col(kAccent, 0.6f), 10 * s, 0, 1.5f * s);
            Text(dl, ImVec2(a.x + pad, a.y + 22 * s), fs * 1.2f, kText, q);
            Text(dl, ImVec2(a.x + pad, a.y + 64 * s), fs * 0.9f, kDim, sub);
            const char *bl[2] = { "Quit", "Cancel" };
            float bx = a.x + pad;
            for (int i = 0; i < 2; i++) {
                ImVec2 ts = TextSize(fs, bl[i]);
                ImVec2 ba(bx, b.y - 64 * s), bb(bx + ts.x + 40 * s, b.y - 20 * s);
                bool hov;
                char id[16];
                snprintf(id, sizeof id, "q%d", i);
                if (Hit(id, ba, bb, &hov)) {
                    if (i == 0)
                        overlay_request(OVERLAY_REQ_QUIT);
                    g_quit_prompt = false;
                }
                dl->AddRectFilled(ba, bb, Col(kAccent, g_quit_sel == i ? 0.30f : hov ? 0.16f : 0.08f), 5 * s);
                if (g_quit_sel == i)
                    dl->AddRect(ba, bb, Col(kAccent), 5 * s, 0, 2 * s);
                Text(dl, ImVec2(ba.x + 20 * s, ba.y + (44 * s - fs) * 0.5f), fs, kText, bl[i]);
                bx = bb.x + 14 * s;
            }
        }
    }

    // ---------------------------------------------------------------- ImGui
    const unsigned char kFont[] = {
#include "overlay_font.inc"
    };
    bool g_imgui;
    double g_last_time;

    void InitImGui(id<MTLDevice> device)
    {
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = nullptr;
        io.LogFilename = nullptr;
        ImFontConfig cfg;
        cfg.FontDataOwnedByAtlas = false;
        io.Fonts->AddFontFromMemoryTTF(const_cast<unsigned char *>(kFont), (int)sizeof kFont, kFontSize, &cfg);
        ImGuiStyle &st = ImGui::GetStyle();
        st.WindowPadding = ImVec2(0, 0);
        st.WindowBorderSize = 0;
        st.FontSizeBase = kFontSize;
        ImGui_ImplMetal_Init(device);
        g_imgui = true;
        fprintf(stderr, "[overlay] Dear ImGui %s on Metal\n", ImGui::GetVersion());
    }
}

// ---------------------------------------------------------------- the C API

extern "C" void overlay_request(int what)
{
    g_requests.fetch_or(1u << what);
}

extern "C" int overlay_is_open(void)
{
    return g_open.load();
}

extern "C" void overlay_toggle(void)
{
    Open(!g_open.load());
}

extern "C" void overlay_settings_load(void)
{
    int n = 0;
    const OverlayOption *t = overlay_game_options(&n);
    g_opts.clear();
    g_pages.clear();
    for (int i = 0; i < n; i++) {
        g_opts.push_back(Opt{ &t[i], t[i].def, t[i].def });
        bool seen = false;
        for (auto &p : g_pages)
            seen |= p == t[i].page;
        if (!seen)
            g_pages.push_back(t[i].page);
    }
    if (FILE *f = fopen(kSettingsFile, "r")) {
        char line[256];
        while (fgets(line, sizeof line, f)) {
            char *eq = strchr(line, '=');
            if (!eq || line[0] == ';' || line[0] == '#')
                continue;
            *eq = 0;
            eq[1 + strcspn(eq + 1, "\r\n")] = 0;
            for (Opt &p : g_opts)
                if (p.o->key && !strcmp(line, p.o->key))
                    for (int j = 0; j < p.o->n; j++)
                        if (!strcmp(eq + 1, p.o->values[j]))
                            p.cur = p.launch = j;
        }
        fclose(f);
    }
    std::string log;
    for (Opt &p : g_opts)
        if (p.o->key) {
            if (p.o->apply)
                p.o->apply(p.cur, 1);
            log += std::string(log.empty() ? "" : ", ") + p.o->key + "=" + p.o->values[p.cur];
        }
    fprintf(stderr, "[overlay] settings: %s\n", log.c_str());
}

extern "C" void overlay_init(SDL_Window *window)
{
    g_window = window;
    g_init_ticks = SDL_GetTicks();
    if (const char *sc = getenv("NFSU2_OVERLAY_SCRIPT")) {
        std::string all(sc);
        size_t i = 0;
        while (i < all.size()) {
            size_t j = all.find(',', i);
            std::string item = all.substr(i, j == std::string::npos ? std::string::npos : j - i);
            size_t c = item.find(':');
            if (c != std::string::npos)
                g_script.push_back(Step{ (Uint32)(atof(item.substr(0, c).c_str()) * 1000.0), item.substr(c + 1) });
            if (j == std::string::npos)
                break;
            i = j + 1;
        }
        fprintf(stderr, "[overlay] test script: %zu steps\n", g_script.size());
    }
    int w = 1, h = 1;
    SDL_GetWindowSize(window, &w, &h);
    g_win_w = w;
    g_win_h = h;
    g_inited = true;
}

extern "C" int overlay_event(const SDL_Event *e)
{
    if (!g_inited)
        return 0;
    switch (e->type) {
    case SDL_WINDOWEVENT:
        if (e->window.event == SDL_WINDOWEVENT_SIZE_CHANGED || e->window.event == SDL_WINDOWEVENT_RESIZED) {
            int w = 1, h = 1;
            SDL_GetWindowSize(g_window, &w, &h);
            g_win_w = w;
            g_win_h = h;
        }
        return 0;
    case SDL_KEYDOWN:
        if (e->key.keysym.scancode == SDL_SCANCODE_F1) {
            if (!e->key.repeat)
                overlay_toggle();
            return 1;
        }
        break;
    case SDL_CONTROLLERBUTTONDOWN:
    case SDL_CONTROLLERBUTTONUP: {
        bool down = e->type == SDL_CONTROLLERBUTTONDOWN;
        g_pad_buttons_down += down ? 1 : -1;
        if (g_pad_buttons_down < 0)
            g_pad_buttons_down = 0;
        Uint8 b = e->cbutton.button;
        if (b == SDL_CONTROLLER_BUTTON_BACK || b == SDL_CONTROLLER_BUTTON_START) {
            Chord *c = nullptr;
            for (auto &x : g_chords)
                if (x.id == e->cbutton.which)
                    c = &x;
            if (!c) {
                g_chords.push_back(Chord{ e->cbutton.which, false, false, false });
                c = &g_chords.back();
            }
            (b == SDL_CONTROLLER_BUTTON_BACK ? c->back : c->start) = down;
            if (c->back && c->start && !c->fired) {
                c->fired = true;
                overlay_toggle();
                return 1;
            }
            if (!c->back && !c->start)
                c->fired = false;
        }
        break;
    }
    default:
        break;
    }
    if (!g_open.load())
        return 0;

    // Open: the menu takes the input.
    switch (e->type) {
    case SDL_KEYDOWN: {
        SDL_Scancode k = e->key.keysym.scancode;
        int a = -1;
        switch (k) {
        case SDL_SCANCODE_UP: case SDL_SCANCODE_W: a = kUp; break;
        case SDL_SCANCODE_DOWN: case SDL_SCANCODE_S: a = kDown; break;
        case SDL_SCANCODE_LEFT: case SDL_SCANCODE_A: a = kLeft; break;
        case SDL_SCANCODE_RIGHT: case SDL_SCANCODE_D: a = kRight; break;
        case SDL_SCANCODE_RETURN: case SDL_SCANCODE_KP_ENTER: case SDL_SCANCODE_SPACE: a = kAccept; break;
        case SDL_SCANCODE_ESCAPE: case SDL_SCANCODE_BACKSPACE: a = kBack; break;
        case SDL_SCANCODE_Q: case SDL_SCANCODE_PAGEUP: a = kPrev; break;
        case SDL_SCANCODE_E: case SDL_SCANCODE_PAGEDOWN: a = kNext; break;
        case SDL_SCANCODE_TAB: a = (e->key.keysym.mod & KMOD_SHIFT) ? kPrev : kNext; break;
        default: break;
        }
        if (a >= 0 && (!e->key.repeat || a <= kRight))
            PushAct(a);
        return 1;
    }
    case SDL_KEYUP:
        return 0;               // the keyboard pad must see its keys go up
    case SDL_TEXTINPUT:
        return 1;
    case SDL_CONTROLLERBUTTONDOWN:
    case SDL_CONTROLLERBUTTONUP: {
        bool down = e->type == SDL_CONTROLLERBUTTONDOWN;
        int a = -1;
        switch (e->cbutton.button) {
        case SDL_CONTROLLER_BUTTON_DPAD_UP: a = kUp; break;
        case SDL_CONTROLLER_BUTTON_DPAD_DOWN: a = kDown; break;
        case SDL_CONTROLLER_BUTTON_DPAD_LEFT: a = kLeft; break;
        case SDL_CONTROLLER_BUTTON_DPAD_RIGHT: a = kRight; break;
        case SDL_CONTROLLER_BUTTON_A: a = kAccept; break;
        case SDL_CONTROLLER_BUTTON_B: a = kBack; break;
        case SDL_CONTROLLER_BUTTON_LEFTSHOULDER: a = kPrev; break;
        case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER: a = kNext; break;
        default: break;
        }
        if (a >= 0) {
            if (a <= kRight)
                down ? Hold(a) : Release(a);
            else if (down)
                PushAct(a);
        }
        return 1;
    }
    case SDL_CONTROLLERAXISMOTION:
        if (e->caxis.axis == SDL_CONTROLLER_AXIS_LEFTX || e->caxis.axis == SDL_CONTROLLER_AXIS_LEFTY) {
            SDL_GameController *gc = SDL_GameControllerFromInstanceID(e->caxis.which);
            if (gc) {
                int x = SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTX);
                int y = SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTY);
                int dir = -1;
                const int on = 20000;
                if (abs(x) > abs(y) && abs(x) > on) dir = x < 0 ? kLeft : kRight;
                else if (abs(y) > on) dir = y < 0 ? kUp : kDown;
                if (dir != g_stick_dir) {
                    if (g_stick_dir >= 0) Release(g_stick_dir);
                    if (dir >= 0) Hold(dir);
                    g_stick_dir = dir;
                }
            }
        }
        return 1;
    case SDL_MOUSEMOTION:
        Push(Ev{ Ev::kMouseMove, 0, (float)e->motion.x, (float)e->motion.y, 0, false });
        return 1;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:
        Push(Ev{ Ev::kMouseButton, 0, (float)e->button.x, (float)e->button.y,
                 e->button.button == SDL_BUTTON_RIGHT ? 1 : 0, e->type == SDL_MOUSEBUTTONDOWN });
        return 1;
    case SDL_MOUSEWHEEL:
        Push(Ev{ Ev::kWheel, 0, 0, (float)e->wheel.y, 0, false });
        return 1;
    case SDL_JOYAXISMOTION:
    case SDL_JOYBUTTONDOWN:
    case SDL_JOYBUTTONUP:
    case SDL_JOYHATMOTION:
        return 1;
    default:
        return 0;
    }
}

extern "C" void overlay_main_tick(void)
{
    while (g_script_next < g_script.size() && SDL_GetTicks() - g_init_ticks >= g_script[g_script_next].ms) {
        const std::string &a = g_script[g_script_next++].act;
        static const char *const names[] = { "up", "down", "left", "right", "accept", "back", "prev", "next" };
        fprintf(stderr, "[overlay] script: %s\n", a.c_str());
        if (a == "open") Open(true);
        else if (a == "close") Open(false);
        else if (a == "shot") g_shot_req = 1;
        else
            for (int k = 0; k < 8; k++)
                if (a == names[k])
                    PushAct(k);
    }
    // Held directions repeat.
    if (g_open.load() && g_held.act >= 0 && SDL_TICKS_PASSED(SDL_GetTicks(), g_held.next)) {
        g_held.next = SDL_GetTicks() + 110;
        PushAct(g_held.act);
    }
    // Cursor: shown while the menu is open.
    if (g_open.load() && g_cursor_before < 0) {
        g_cursor_before = SDL_ShowCursor(SDL_QUERY);
        SDL_ShowCursor(SDL_ENABLE);
    }
    // Closed: the pad goes back to the game once nothing is held.
    if (g_closing.load()) {
        if (g_cursor_before >= 0) {
            SDL_ShowCursor(g_cursor_before);
            g_cursor_before = -1;
        }
        int keys = 0, nk = 0;
        const Uint8 *ks = SDL_GetKeyboardState(&nk);
        for (int i = 0; i < nk; i++)
            keys |= ks[i];
        if (!keys && g_pad_buttons_down == 0 && g_stick_dir < 0) {
            g_held.act = -1;
            xbox_input_blocked = 0;
            g_closing = 0;
        }
    }
    unsigned r = g_requests.exchange(0);
    if (!r)
        return;
    if (r & (1u << OVERLAY_REQ_FULLSCREEN_ON))
        apple_set_fullscreen(1);
    if (r & (1u << OVERLAY_REQ_FULLSCREEN_OFF))
        apple_set_fullscreen(0);
    if (r & (1u << OVERLAY_REQ_OPEN_LOGS)) {
        char cwd[1024];
        if (getcwd(cwd, sizeof cwd)) {
            NSString *p = [[[NSString stringWithUTF8String:cwd] stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"logs"];
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:p isDirectory:YES]];
        }
    }
    if (r & (1u << OVERLAY_REQ_QUIT)) {
        fprintf(stderr, "[overlay] Quit Game\n");
        fflush(stdout);
        fflush(stderr);
        _exit(0);
    }
}

extern "C" void overlay_present_metal(void *command_buffer, void *texture)
{
    if (!g_open.load())
        return;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)command_buffer;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    if (!g_imgui)
        InitImGui(tex.device);

    ImGuiIO &io = ImGui::GetIO();
    const float W = (float)tex.width, H = (float)tex.height;
    io.DisplaySize = ImVec2(W, H);
    io.DisplayFramebufferScale = ImVec2(1, 1);
    double now = CACurrentMediaTime();
    io.DeltaTime = g_last_time > 0 ? (float)fmax(now - g_last_time, 1e-4) : 1.0f / 60.0f;
    g_last_time = now;

    if (g_just_opened.exchange(0)) {
        g_page = 0;
        g_row = PageRows(0).empty() ? -1 : 0;
        g_footer = g_row < 0 ? 1 : -1;
        g_first = 0;
        g_quit_prompt = false;
    }
    std::vector<Ev> evs;
    {
        std::lock_guard<std::mutex> lock(g_queue_lock);
        evs.swap(g_queue);
    }
    const float mx = W / (float)g_win_w.load(), my = H / (float)g_win_h.load();
    for (const Ev &e : evs) {
        switch (e.kind) {
        case Ev::kAct: HandleAct(e.act); break;
        case Ev::kMouseMove: io.AddMousePosEvent(e.x * mx, e.y * my); break;
        case Ev::kMouseButton:
            io.AddMousePosEvent(e.x * mx, e.y * my);
            io.AddMouseButtonEvent(e.button, e.down);
            break;
        case Ev::kWheel: io.AddMouseWheelEvent(0, e.y); break;
        }
        if (!g_open.load())
            return;
    }

    Layout L;
    L.s = H / 720.0f;
    float pw = fminf(1060.0f * L.s, W - 60.0f * L.s), ph = 660.0f * L.s;
    L.p0 = ImVec2((W - pw) * 0.5f, (H - ph) * 0.5f);
    L.p1 = ImVec2(L.p0.x + pw, L.p0.y + ph);
    ImGui::GetStyle().FontScaleMain = L.s;

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    ImGui_ImplMetal_NewFrame(rp);
    ImGui::NewFrame();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(io.DisplaySize);
    ImGui::Begin("overlay", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoBackground |
                 ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoNav |
                 ImGuiWindowFlags_NoBringToFrontOnFocus);
    DrawMenu(L);
    ImGui::End();
    ImGui::Render();
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];

    const char *shot = getenv("NFSU2_OVERLAY_SHOT");
    if (shot && g_shot_req.exchange(0) && !tex.framebufferOnly) {
        NSUInteger w = tex.width, h = tex.height, row = w * 4;
        id<MTLBuffer> buf = [tex.device newBufferWithLength:row * h options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row * h];
        [bl endEncoding];
        std::string path = std::string(shot) + std::to_string(g_shot_n++) + ".bmp";
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            FILE *f = fopen(path.c_str(), "wb");
            if (!f)
                return;
            uint32_t size = 54 + (uint32_t)(row * h);
            uint8_t hd[54] = { 'B', 'M' };
            memcpy(hd + 2, &size, 4);
            uint32_t off = 54, hs = 40, img = (uint32_t)(row * h);
            int32_t iw = (int32_t)w, ih = -(int32_t)h;      // top-down
            uint16_t planes = 1, bpp = 32;
            memcpy(hd + 10, &off, 4); memcpy(hd + 14, &hs, 4); memcpy(hd + 18, &iw, 4); memcpy(hd + 22, &ih, 4);
            memcpy(hd + 26, &planes, 2); memcpy(hd + 28, &bpp, 2); memcpy(hd + 34, &img, 4);
            fwrite(hd, 1, 54, f);
            fwrite(buf.contents, 1, row * h, f);
            fclose(f);
            fprintf(stderr, "[overlay] shot %s\n", path.c_str());
        }];
    }
}
