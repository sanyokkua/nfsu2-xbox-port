"""A call target that splits a decoded instruction is dropped only when every
call to it comes from outside the detected functions (a call decoded out of
data, like NFS Carbon's XPP header calling into its USB enumerator)."""
from types import SimpleNamespace as NS

from tools.disasm.functions import FunctionDetector


def detector(callers):
    det = FunctionDetector.__new__(FunctionDetector)
    det._split_call_targets = {0x1050}
    det._candidates = {0x1000: (0.9, "prologue"), 0x1050: (0.8, "call_target")}
    det.functions = {0x1000: NS(start=0x1000, end=0x1100)}
    det.engine = NS(instructions={a: NS(address=a, is_call=True, call_target=0x1050)
                                  for a in callers})
    return det


def test_split_target_called_only_from_data_is_dropped():
    det = detector([0x2000])            # caller outside every function
    assert det._prune_data_call_targets()
    assert 0x1050 not in det._candidates


def test_split_target_called_from_code_is_kept():
    det = detector([0x2000, 0x1010])    # one caller inside sub_1000
    assert not det._prune_data_call_targets()
    assert 0x1050 in det._candidates


def chain_detector(second_caller_of_0x3000):
    """sub_3000 is a call target whose only caller (0x2000) lies outside every
    function -- a body decoded out of data. Its own decoded "call" (0x3010)
    splits an instruction of the real sub_1000 at 0x1050."""
    det = FunctionDetector.__new__(FunctionDetector)
    det._split_call_targets = {0x1050}
    det._candidates = {0x1000: (0.9, "prologue"), 0x1050: (0.8, "call_target"),
                       0x3000: (0.8, "call_target")}
    det.functions = {0x1000: NS(start=0x1000, end=0x1100),
                     0x3000: NS(start=0x3000, end=0x3100)}
    calls = {0x2000: 0x3000, 0x3010: 0x1050}
    if second_caller_of_0x3000:
        calls[0x1020] = 0x3000              # a call from real code
    det.engine = NS(instructions={a: NS(address=a, is_call=True, call_target=t)
                                  for a, t in calls.items()})
    return det


def test_split_target_called_from_a_function_decoded_out_of_data_is_dropped():
    # PoA: XGRPH's tables decode as sub_002B48AE (called only from data), whose
    # "call 0x002B87FF" cut DSOUND's pool allocator after ExQueryPoolBlockSize.
    det = chain_detector(second_caller_of_0x3000=False)
    assert det._prune_data_call_targets()
    assert 0x1050 not in det._candidates
    assert 0x3000 in det._candidates        # only discounted as evidence, not removed


def test_split_target_called_from_a_function_with_a_real_caller_is_kept():
    det = chain_detector(second_caller_of_0x3000=True)
    assert not det._prune_data_call_targets()
    assert 0x1050 in det._candidates
