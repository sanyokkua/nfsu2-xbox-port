/*
 * apple_player.c -- the player folder of the Mac app.
 *
 * When NFSU2_GAME_DIR is not set (the app opened from Finder), everything the
 * game reads and writes lives in ~/Library/Application Support/NFS Underground 2:
 *
 *   game/      the player's disc, put there by the installer (the game's own
 *              saves, UDATA/, are written here too)
 *   saves/     the kernel's partitions (XDG_DATA_HOME)
 *   cache/     shader cache (XDG_CACHE_HOME)
 *   player/    the working directory: settings.ini (Settings window) and
 *              nfsu2x_options.txt (the game's Options rows)
 *   logs/      nfsu2.log (stdout and stderr when not on a terminal), the five
 *              before it as nfsu2.log.1 .. .5
 *
 * Variables already set win (tests, tools/play.sh).
 */
#include <TargetConditionals.h>
#if defined(__APPLE__) && !TARGET_OS_IPHONE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define PLAYER_ROOT "/Library/Application Support/NFS Underground 2"

static void mkdirs(const char *path)
{
    char p[PATH_MAX];
    char *s;

    snprintf(p, sizeof p, "%s", path);
    for (s = p + 1; *s; s++)
        if (*s == '/') {
            *s = 0;
            mkdir(p, 0755);
            *s = '/';
        }
    mkdir(p, 0755);
}

static void sub(char *out, size_t n, const char *root, const char *name)
{
    snprintf(out, n, "%s/%s", root, name);
    mkdirs(out);
}

static void open_log(const char *logs)
{
    char a[PATH_MAX], b[PATH_MAX];
    int i, fd;
    time_t t = time(NULL);

    for (i = 4; i >= 0; i--) {
        if (i)
            snprintf(a, sizeof a, "%s/nfsu2.log.%d", logs, i);
        else
            snprintf(a, sizeof a, "%s/nfsu2.log", logs);
        snprintf(b, sizeof b, "%s/nfsu2.log.%d", logs, i + 1);
        rename(a, b);
    }
    snprintf(a, sizeof a, "%s/nfsu2.log", logs);
    fd = open(a, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        return;
    dup2(fd, 1);
    dup2(fd, 2);
    close(fd);
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("=== %s", ctime(&t));
}

void apple_player_setup(void)
{
    const char *home = getenv("HOME");
    char root[PATH_MAX], dir[PATH_MAX];

    if (getenv("NFSU2_GAME_DIR") || !home)
        return;                             /* a test or tools/play.sh: its own folders */
    snprintf(root, sizeof root, "%s" PLAYER_ROOT, home);
    sub(dir, sizeof dir, root, "logs");
    if (!isatty(2))
        open_log(dir);
    snprintf(dir, sizeof dir, "%s/game", root);
    setenv("NFSU2_GAME_DIR", dir, 1);
    sub(dir, sizeof dir, root, "saves");
    setenv("XDG_DATA_HOME", dir, 0);
    sub(dir, sizeof dir, root, "cache");
    setenv("XDG_CACHE_HOME", dir, 0);
    sub(dir, sizeof dir, root, "player");
    if (chdir(dir) != 0)
        fprintf(stderr, "[player] cannot enter %s: %s\n", dir, strerror(errno));
    fprintf(stderr, "[player] %s (game, saves, cache, player, logs)\n", root);
}

/* The installed disc: 1 if game/default.xbe is there. */
int apple_player_has_game(void)
{
    char p[PATH_MAX];
    const char *g = getenv("NFSU2_GAME_DIR");

    if (!g)
        return 1;
    snprintf(p, sizeof p, "%s/default.xbe", g);
    return access(p, R_OK) == 0;
}

#endif
