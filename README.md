# Arkari Builds

使用 GitHub Actions 构建 [SakuraFox-GC/Arkari](https://github.com/SakuraFox-GC/Arkari) 的 Windows x64 工具链。本仓库只保存构建配置，源码在 CI 中浅克隆；本地无需克隆 LLVM。

入口工作流**只有 `workflow_dispatch`**，不会因 push、PR 或定时任务运行。

## 手动构建

1. 打开 [Actions → Build Arkari for Windows](https://github.com/SakuraFox-GC/Arkari-Builds/actions/workflows/build-windows.yml)。
2. 点击 **Run workflow**，选择 Arkari 的分支、tag 或 commit；默认 `llvm-23.x`。
3. `build_type` 可选 **Release / Debug**，默认 **Release**；`parallel_jobs` 默认为 `0`，使用 runner 的 CPU 数。`parallel_link_jobs` 默认 `0`，不额外限制链接并发，仍服从 `parallel_jobs` 的总并发上限；设为正整数可单独限制同时运行的链接任务数。
4. 如需 LTO，勾选 **`build_lto`**；默认只构建普通版本。
   如果已有启用 LTO 时生成且通过 BLA 回归的普通包，可在 `native_run_id` 填入其 Actions run ID，复用普通包、源码 commit 和静态依赖；留空则重新构建普通版。复用时 `build_type` 必须匹配，源码以该普通包的记录为准。集成验收首次构建应留空，旧源码生成的普通包不能用来验证新功能。
5. 成功后从该次运行的 **Artifacts** 下载工具链 `.7z`、SHA256 和 `build-info.json`。产物保留 14 天；LTO 合并包名称包含 `ThinLTO`。

也可手动使用 GitHub CLI：

```sh
gh workflow run build-windows.yml --repo SakuraFox-GC/Arkari-Builds \
  -f arkari_ref=llvm-23.x -f build_type=Release -f parallel_jobs=0 -f parallel_link_jobs=0 -f build_lto=true
```

Runner 镜像通过仓库的 Actions Variable **`WINDOWS_RUNNER_IMAGE`** 配置，可在 [Settings → Secrets and variables → Actions → Variables](https://github.com/SakuraFox-GC/Arkari-Builds/settings/variables/actions) 修改；未配置时使用 `windows-2025-vs2026`。工作流自动检测已安装的 Visual Studio x64 开发环境。完整 LLVM 构建可能耗时数小时；单次 job 的超时为 360 分钟。

## ThinLTO 分 job 构建

启用 `build_lto` 后会串行运行以下 job，全部继承相同的 `build_type`，每个 job 各有 360 分钟限额：

1. **Native toolchain**：使用 VS 随附的 LLVM 构建普通 Arkari，保留原生库，并提供下一阶段的 Arkari、`llvm-tblgen` 和静态依赖。
2. **Compile ThinLTO objects**：使用普通 Arkari 配置 `LLVM_ENABLE_LTO=Thin`，只编译 distribution 所需的目标文件及生成代码所需的工具，然后保存构建目录。
3. **Link and install ThinLTO**：恢复目标文件、Ninja 状态、生成文件和 LTO cache，继续链接并安装。源码时间戳保持一致，链接前验证构建参数和工具链，并确认 Ninja 不会重新编译上一步的目标文件。compiler-rt / OpenMP 的嵌套构建在此阶段完成。
4. **Merge, verify and package ThinLTO**：只将 LTO `bin` 覆盖到普通工具链，保留普通版的 `lib`、头文件、资源和许可证，然后检查并打包。

LTO 各 job 固定普通版的 Arkari / rpmalloc commit，并直接复用普通版的静态依赖。中间 artifact 保留 2 天；链接失败可重跑失败 job，复用已完成的编译。合并前要求普通 DLL 的全部导出保留，并检查 EXE 的插件注册入口和 `Type::getAs` 非内联显式特化接口；自动导出的 EXE 内联辅助函数可随优化变化，差异数量记录在构建信息中。合并后验证普通库文件的 SHA256 未变化，再使用 MSVC 链接普通版 `libclang.lib` 和 `LLVM-C.lib`，加载 LTO DLL 并运行，检查混合分发包的兼容性。

已完成链接时，可在 [Actions → Merge and package ThinLTO](https://github.com/SakuraFox-GC/Arkari-Builds/actions/workflows/package-lto.yml) 手动填写 `native_run_id`、`lto_run_id` 和 `build_type`，直接复用已有二进制进行合并、验证和打包。如果旧产物的 `LLVM-C.dll` 丢失 C API 导出，会复用尚未过期的目标文件，只重新生成该 DLL 的导出列表并链接。

构建时会给 LLVM 的 `gen-msvc-exports.py` 应用小补丁，使其兼容 bitcode 符号没有数字地址的输出格式，避免生成空的 LLVM-C 导出列表。补丁记录在 `build-info.json` 的 `source_patches` 中。

普通包和最终 `ThinLTO` 合并包都会保留。普通 artifact 中的 `bootstrap` 目录用于 job 之间传递构建依赖，不需要随工具链解压。

## 构建内容

| 项目 | 配置 |
| --- | --- |
| 构建类型 | Release（默认）/ Debug，静态 CRT（`/MT` / `/MTd`） |
| LLVM 项目 | clang、clang-tools-extra、lld、lldb |
| 代码生成目标 | X86（x86 / x64）、AArch64 |
| Runtimes | compiler-rt、OpenMP；关闭 compiler-rt ORC |
| 分发组件 | 沿用提供的 `distribution` 组件列表，见 `scripts/Build.ps1` |
| 分配器 | 单独浅克隆 `mjansson/rpmalloc` 的 `develop` 最新提交 |
| vcpkg | `zlib`、`liblzma`、`libxml2`，均为 `x64-windows-static` |
| LLDB | 禁用 Python，启用 LZMA / libxml2 |

Release 使用 `LLVM_ENABLE_RPMALLOC=OFF`，并将 `LLVM_INTEGRATED_CRT_ALLOC` 指向外部 rpmalloc，避免被 in-tree rpmalloc 覆盖。每次构建记录 rpmalloc 的确切 commit。Debug 按 LLVM 的限制关闭集成分配器，启用断言，并使用 `/MTd`。

CMake 的 `optimized;…;debug;…` 日志表示同时找到两套依赖路径，实际按 `build_type` 选择对应库，并不表示正在构建 Debug。

直接复用镜像预装的 vcpkg（`VCPKG_INSTALLATION_ROOT`，当前为 `C:\vcpkg`），无需 clone 或 bootstrap。`vcpkg.json` 声明三个静态依赖，依赖版本跟随镜像预装的 ports；实际 vcpkg commit 写入构建信息，并用于区分二进制缓存。`libLZMA` 的 vcpkg port 名称实际为小写 `liblzma`。

以 Visual Studio 随附的 clang-cl / lld-link / llvm-lib 引导构建（当前镜像为 LLVM 22.1.3，兼容 VS 2026 STL）；`llvm-tblgen` 从本次源码编译，避免复用其他 LLVM 版本的生成器。DIA SDK 由 VS 安装目录定位，不使用本机路径。配置中的 Zlib / libxml2 / LZMA 为必需依赖；未请求的 Zstd 支持关闭。

安装后会验证 clang、lld、lldb、clangd 能启动，按所选配置使用 `/MT` 或 `/MTd` 编译并运行 C++ 程序，生成 x64 / x86 / AArch64 对象，编译和运行 OpenMP 程序，并通过 MSVC 链接、运行 libclang 和 LLVM-C 程序。普通版和合并版还会开启全部 8 项 Arkari 保护，将可调强度设为最高 3 级，并使用固定的 32 字节 RTTI 种子编译一个由两个 C++ 源文件组成的小型库存统计程序：读取 CSV，使用 `std::string` / `std::vector` 解析、筛选和排序 12 条记录，通过多态计价计算数量与金额汇总，并处理 2 条错误数据。测试覆盖文件 I/O、堆内存管理、分支、间接调用、全局变量、整数与浮点计算、跨文件 RTTI / `dynamic_cast` 及异常；以 8 组输入运行，与未混淆的同一程序逐项比较输出，并检查字符串加密和 RTTI 名称擦除实际生效。单次程序运行超过 30 秒会失败。

已有工具链可在 [Actions → Smoke test saved toolchain](https://github.com/SakuraFox-GC/Arkari-Builds/actions/workflows/smoke-test.yml) 手动填写产物所在的 `run_id` 补测，无需重新编译 LLVM；同一次运行有多个工具链包时填写 `artifact_name`。测试报告和诊断文件保留 7 天。

## 测试失败后的 Native SDK 检查点

Native 已完成编译和安装、但 smoke 测试失败时，CI 会额外保存 `unverified-Arkari-Windows-x64-*` 检查点，包含已编译 SDK、静态依赖 bootstrap、元数据和 SHA256，保留 2 天。原 job 仍标记失败；该检查点的 `validation_state=unverified`，不会作为正常工具链发布，也不会被 `native_run_id` 自动接受。

恢复时在 **Smoke test saved toolchain** 填写检查点所在的 `run_id`，显式勾选 **`recover_unverified`**，并保持 `test_bla` 开启。流程会校验和恢复检查点、浅取固定源码 commit 的测试头文件，重新执行完整基础工具链、ABI、原保护及 BLA 回归。全部通过后才改为 `validation_state=verified`，重打带 bootstrap 的正常 Native 包，保留 14 天；后续完整构建的 `native_run_id` 使用这次恢复运行的 ID。恢复保留原 SDK 的源码版本，只重跑测试与打包。

所有 smoke 入口通过 [Clang 官方支持的 `CLANG_CRASH_DIAGNOSTICS_DIR`](https://clang.llvm.org/docs/UsersManual.html#options-to-control-clang-crash-diagnostics) 将崩溃重现文件写入 `arkari-smoke/crash-diagnostics`。预处理源码、重现脚本及 driver 生成的关联文件随 smoke artifact 上传；测试目录中的对象、IR、PE 和完整命令日志也一并保留。

## BLA 通用保护回归

本 CI 版本要求 Arkari 源码包含 BLA 通用保护集成。上游固定为 [`qybaihe/bla` 的 `dd9e72f5`](https://github.com/qybaihe/bla/tree/dd9e72f53ad97e3eb228523ad25295029107bb63)，仅移植通用机制，不加入 Rust / Go / Flutter / Electron 专属预算载荷或运行期反调试。构建前读取源码中的 `Bla/upstream.json` 核对来源；不下载 BLA、不安装 Node.js，也不开启 LLVM 全量测试。

新增保护默认全部关闭。IR 通过 `-mllvm` 传入 `-irobf-bla-mba`、`-irobf-bla-opaque`、`-irobf-bla-decoy`、`-irobf-bla-meta`，强度同样通过 `-mllvm -level-bla-名称=0..3` 设置；启用后的 `0` 为最低强度，仅指定强度不会启用。JSON 顶层使用同名 `bla-*` 对象的 `enable` / `level`。MBA 和不透明谓词支持函数 annotation，优先级为 JSON、显式命令行、函数 annotation。

linker 独立使用 `/arkari-bla-pe`、`/arkari-bla-pe:no`、`/arkari-bla-pe-level:0..3`、`/arkari-cfg:路径`；JSON 对应 `linker.bla-pe`。将 JSON 传给编译器不会自动开启链接器保护。固定 `randomSeed` 可复现生成的诱饵结构。编译工具链本身保持这些保护关闭，只在回归样例上显式启用。

普通版和最终合并版都会运行同一组定向检查：

- IR 全关、仅指定强度、四项独立功能的 0–3 级、无效强度、JSON / CLI / annotation 优先级、固定种子与重复处理；无手工 `noinline` 的静态函数也验证正、负 annotation 的边界在 O2 内联前保留。
- x64、x86 的实际程序运行：库存程序的原保护、BLA 四档、组合、应用 ThinLTO 及 BLA 与 Control Flow Guard 的组合，逐项对照未混淆程序的 8 组输出；另测 49 组算术边界组合、4096 组伪随机输入、4 线程重复调用及 DLL 导出 / import library / 加载运行。
- 新旧 pass 兼容矩阵复用同一库存程序：先验证旧 8 项各自单独开启，再让新 4 项 IR 保护及 PE 保护分别与旧 8 项逐项配对，强度设为 3；x64、x86 各 40 对，输入 `0`、`19`、`256` 与同一未保护基线比较。IR-only 配对要求 PE 保护保持关闭，PE-only 配对要求未生成任何新 IR 对象；检查业务字符串加密、真实 RTTI 名称擦除以及语义诱饵仍为明文。报告记录每对的输出摘要、实际进程退出码和日志名称，首个失败保留已完成结果并明确指出配对名称。
- 库存控制项还单独测试旧保护全开 ThinLTO、仅 BLA 全开 ThinLTO，以及旧保护全开配合新保护全部最低强度，便于区分旧 pass 自身的 LTO 问题、强度问题与新旧交互。
- x64、x86、AArch64 的 IR / COFF / PE 结构检查：普通优化、应用 ThinLTO、`/OPT:REF` 和 `/OPT:ICF` 后的诱饵数量、只读节权限、最终 RVA 索引、真实重定位与固定输入清单一致性；两个可跨 TU 导入的源文件分别编译 bitcode，再通过 ThinLTO / FullLTO 链接，严格要求 64 个诱饵和 2 个 metadata，防止导入副本重复生成。AArch64 不在 x64 runner 上执行。

这些检查使用已分发的 clang、lld-link、readobj 和 objdump，Python 只使用标准库。测试程序单次运行限时 30 秒，编译命令限时 5 分钟；失败会阻止工具链打包。报告、IR、COFF、PE 和命令日志上传为 `arkari-smoke-native-*` / `arkari-smoke-lto-*`，保留 7 天。手动补测默认包含 BLA；对旧版产物可取消 `test_bla`，只运行原有保护测试。

`build-info.json` 包含源码、rpmalloc、vcpkg 和构建配置的 commit，以及实际 CMake 参数；`bla_integration` 记录上游来源和功能范围，`bla_validation` 记录通过的回归组、测试配置 commit、运行链接和架构。合并包记录普通版和 LTO 的信息，继续保留并校验普通版库文件。

Arkari 的源码 checkout 不会被打包上传。中间 artifact 保存构建输出；最终工具链包附带 LLVM、BLA、rpmalloc 和 vcpkg 依赖的许可证，BLA 的上游 MIT 文本保存在 `licenses/BLA-MIT-LICENSE.txt`。

## 许可

本仓库的构建脚本采用 MIT 许可证。Arkari / LLVM、rpmalloc 及其他依赖保留各自的许可证。
