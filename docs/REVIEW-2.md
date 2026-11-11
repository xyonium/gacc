# 审计结论

## 1. 结论
可以发布，但需进行以下小规模修正。

## 2. 必须修
- `gaccounts/bin/gacc:349`：在 `FONTS=1` 时使用了 `echo "✔ 已生成账户 $ACC 的字体子集"`，但 `gen-fonts.sh` 可能在特定环境失败。建议检查 `$?`，如果生成字体失败，应该阻止 `prepare_profile` 或至少报 warning，否则会导致 Firefox 启动时找不到字体（即 CJK 缺失）。
- `gaccounts/bin/gacc:107`：递归调用 `load_persona` 是好的，但如果 `gen_persona` 也失败（比如 `PERSONAS` 数组遍历完没合适的），会导致死循环。增加一个 `count` 限制，防止死循环。
- `deploy-gacc.sh:127`：`curl` 的 `-C -`（断点续传）在某些服务器上会返回 416 错误导致下载失败。如果遇到 416，应该回退并重新开始下载。

## 3. 建议修（按严重度）
- 【高】`deploy-gacc.sh` 的 `ldd` 补依赖脚本：如果系统已有这个 `so` 但版本过旧（比如旧版本的 `libgtk-3-0`），`dpkg -x` 解压到 `libs/root` 可能会导致冲突，建议先判断版本或更安全地安装。
- 【中】`install-shortcuts.sh`（暂未完全审完）：在写 `.lnk` 时，如果有包含特殊字符的路径，Windows 的 `powershell` 需要做转义。请增加一层 `EscapedPath` 的校验。
- 【低】`README.md`：需要增加一段关于 WSL2 配置 `networkingMode=mirrored` 的建议，因为这是目前最顺滑的代理配置方式。

## 4. 文档与代码不一致清单
- README 说 `--fonts` 会生成字体，但代码 `gacc` 里的 `FONTS=9` 在初始化时未定义默认行为，实际可能是 `FONTS=9`导致在某些条件下既不生成也不移除。请明确初始化值。
- README 中关于 `--doctor` 的输出：代码中 `cmd_doctor` 的输出比 README 描述的丰富，建议补全文档。

## 5. 仓库就绪度清单
- `.gitignore`: 必须包含 `profiles/acc*/cookies.sqlite`（排除登录状态）、`runtime/`（运行时数据）、`firefox/`（可执行文件下载项）。
- 目录结构：`deploy-gacc.sh` 放根目录是可以的，它是入口点。
- LICENSE：建议加一个 MIT。
- README 建议：增加「常见问题」一节，尤其是关于沙箱黄条的解释，用户非常容易在没理解时去尝试「修复」导致更多错误。

## 6. 「如果只能改 3 处」排序
1. 修复 `gen-fonts.sh` 失败时的错误处理（保证不会出现空字体目录）。
2. 修复 `gacc` 中 `load_persona` 的递归潜在死循环风险。
3. 增加 `.gitignore` 以防止误提交 `profiles/` 下的敏感登录态文件。
