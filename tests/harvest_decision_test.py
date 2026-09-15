"""harvest.service_action 的回归测试 —— 锁住 2026-09-15 修复的缺陷:

「配置无差异就跳过」让新环境永远建不出 selector Secret: 配置已存在但 selector 里还没有该服务的
token 时, 必须走到签发那一步。同时锁住另一侧: 无差异且已有 token 时确实要跳过(否则每次 harvest
都会白白签新 token / 涨 revision)。

    PYTHON=.venv-tools/bin/python bash tests/mapping_test.sh   # 由 mapping_test.sh 顺带执行
"""
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("harvest", HERE.parent / "tools" / "config-center" / "harvest.py")
harvest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harvest)  # type: ignore[union-attr]

# (has_changes, seeded, rotate_tokens, has_selector_token) -> expected
CASES = [
    # 新环境: 配置已在 Config Center, selector 里没有 → 只签 token, 不涨 revision(缺陷所在)
    ((False, False, False, False), "token-only"),
    # 稳态: 无差异且 selector 已有 token → 跳过(不能每轮都签新 token)
    ((False, False, False, True), "skip"),
    # --rotate-tokens: 无差异也要重签
    ((False, False, True, True), "token-only"),
    # 有差异 → 写(有无 token 都进写路径, 签发在写路径里按需做)
    ((True, False, False, True), "write"),
    ((True, False, False, False), "write"),
    # 从模板合成 → 写
    ((False, True, False, False), "write"),
    ((False, True, True, True), "write"),
]

failed = 0
for args, want in CASES:
    got = harvest.service_action(*args)
    mark = "✔" if got == want else "✘"
    if got != want:
        failed += 1
    print(f"  {mark} service_action{args} = {got!r}" + ("" if got == want else f"  (want {want!r})"))
if failed:
    print(f"✘ harvest 决策回归: {failed} 例失败", file=sys.stderr)
    sys.exit(1)
print(f"✔ harvest 决策回归通过: {len(CASES)} 例")
