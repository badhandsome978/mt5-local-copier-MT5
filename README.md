# MT5 Local Copier · MT5 本地交易复制器

轻量级 Windows 小窗口，把同一电脑上源端 MT5 的持仓、挂单与平仓同步到另一个 MT5。源端可以继续运行原来的量化 EA，复制器挂在独立图表上。

A lightweight local trade copier for two MetaTrader 5 terminals on the same Windows computer. Includes a standalone desktop app, MQL5 EAs, and source code. Hedging accounts only.

## 下载与使用

**[下载 v2.00 免安装版 ZIP](https://github.com/badhandsome978/mt5-local-copier-MT5/raw/refs/heads/main/downloads/MT5LocalCopier-v2.00-portable.zip)** · [详细使用说明](安装与使用说明.md) · [验证记录](验证记录.md)

解压并双击 `MT5交易复制器.exe`。无需 Python 或第三方 DLL；EXE 内置两端 EA。运行环境为 Windows 10/11 x64、.NET Framework 4.x，两端 MT5 必须在同一 Windows 用户下使用 **Hedging（对冲）账户**。

1. 在两个 MT5 分别选择“文件 → 打开数据文件夹”。
2. 软件中选择对应目录，分别点“复制到源端”和“复制到接收端”。
3. MT5 导航器刷新 EA 列表，源端独立图表挂 `LocalCopier/CopierSource`，接收端独立图表挂 `LocalCopier/CopierReceiver`；开启算法交易并允许接收 EA 交易。不要替换正在运行量化策略的图表 EA。
4. 核对两个账号，设置手数，点击“启动”；再次点击则停止。

首次需要各挂载一次 EA，之后用小窗口启动、停止。启动会同步源端已有持仓和挂单。配置保存在本机用户目录，无需把账户密码交给软件。

## 功能

- 跟随市价开仓、平仓、部分平仓，以及入场挂单的新增、修改、撤销。
- 源端挂单成交、接收端尚未成交时，先撤销接收挂单并确认，再按缺失手数市价补仓。
- 源端实际平仓（包括止盈止损）后，按剩余持仓跟随平仓。
- 优先撤销冲突挂单、平仓和减仓，再补开缺失仓位，最后同步保护价和入场挂单。
- 检查心跳、校验和和账户绑定；不明确的交易回报会暂停并等待人工核对。

| 手数模式 | 行为 |
| --- | --- |
| 完全同步 | 目标手数等于源端手数 |
| 手数换算 | 源端手数乘以或除以设置值 |
| 固定手数 | 每笔初始手数使用设置值，部分平仓按源端剩余比例缩减 |

换算可选保留两位四舍五入，或直接舍去第三位及以后的小数。例如 `0.32 ÷ 3` 分别为 `0.11` 或 `0.10`。最终还需符合接收券商的最小手数和步长；低于最小手数时不开仓。

## 当前行为与限制

- **停止或关闭窗口会停止跟单、尝试撤销复制入场挂单，保留已有持仓。停止后不会继续跟平。**“停止中”表示撤单尚未完成。
- 默认 `SOURCE_TRIGGERED`：接收端不独立设置 SL/TP，由源端实际平仓触发跟平。电脑、MT5 或网络停止时，接收端没有独立止盈止损保护。可选独立保护价的行为见详细说明。
- 仅支持同机同用户的一组终端及 Hedging 账户，不支持 Netting。不同券商品种名需要在接收 EA 的 `SymbolMap` 中映射。
- 属于状态采样复制，可能漏掉采样窗口内已完整开平的极短交易。50ms 轮询不是成交延迟保证，不能保证同时、同价或逐笔无损。
- **已通过编译和离线测试，尚未完成券商端到端成交测试。** 首次请使用模拟账户验证；不要把离线测试结果当作真实成交或资金安全保证。

完整的停止、断线恢复、模糊成交恢复及更换账户步骤见[安装与使用说明](安装与使用说明.md)。

## 源码与构建

| 路径 | 内容 |
| --- | --- |
| `Desktop/` | C# WinForms 窗口、打包脚本及桌面自测 |
| `Experts/LocalCopier/` | MQL5 源码、共享协议与预编译 EA |
| `tests/` | 共享核心测试、MQL5 协议脚本、隔离 UI 测试入口 |
| `MT5Copier.exe` | 与当前发布对应的桌面程序，内嵌两端 EA |
| `downloads/` | 包含 EXE、简短使用说明和许可证的免安装包 |

先使用 MT5 自带的 MetaEditor 编译 `CopierSource.mq5`、`CopierReceiver.mq5`，生成同目录的 `.ex5`，再在 Windows PowerShell 执行：

```powershell
& .\Desktop\Build.ps1
```

脚本使用系统 .NET Framework x64 C# 编译器，输出根目录 `MT5Copier.exe`。修改 EA 后必须先重新编译 EA，再重建 EXE，才能更新内嵌文件。仓库和下载包中的二进制不会因修改源码而自动更新。

核心测试使用 C++17 编译器，可在 Linux/macOS 或有 g++ 的 Windows 环境执行：

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Werror tests/core_tests.cpp -o core_tests
./core_tests
```

桌面自测在 Windows PowerShell 执行，不连接 MT5、不发单：

```powershell
$report = Join-Path $env:TEMP 'MT5Copier-self-test.txt'
$process = Start-Process -FilePath .\MT5Copier.exe -ArgumentList @('--self-test', ('"' + $report + '"')) -Wait -PassThru
Get-Content -LiteralPath $report
if ($process.ExitCode -ne 0) { throw 'Self-test failed' }
```

GitHub Actions 自动运行共享核心测试，并在 Windows 重建窗口和运行桌面自测。CI 使用仓库已提交的 `.ex5`，不会编译或执行 MQL5，也不会连接交易账户。

## 反馈与许可证

问题请通过 [Issues](https://github.com/badhandsome978/mt5-local-copier-MT5/issues) 提交，说明复现步骤、MT5 版本、账户模式和已脱敏日志。贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

采用 [MIT License](LICENSE)，允许使用、修改与分发，须保留许可证。MetaTrader 5 为其权利人的产品，本项目为独立工具，与其无隶属关系。
