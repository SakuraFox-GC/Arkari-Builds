# Arkari Builds

使用 GitHub Actions 构建 [SakuraFox-GC/Arkari](https://github.com/SakuraFox-GC/Arkari) 的 Windows x64 工具链。本仓库只保存构建配置，源码在 CI 中浅克隆；本地无需克隆 LLVM。

入口工作流**只有 `workflow_dispatch`**，不会因 push、PR 或定时任务运行。

## 手动构建

1. 打开 [Actions → Build Arkari for Windows](https://github.com/SakuraFox-GC/Arkari-Builds/actions/workflows/build-windows.yml)。
2. 点击 **Run workflow**，选择 Arkari 的分支、tag 或 commit；默认 `llvm-23.x`。
3. `build_type` 可选 **Release / Debug**，默认 **Release**；`parallel_jobs` 默认为 `0`，使用 runner 的 CPU 数。`parallel_link_jobs` 默认 `0`，不额外限制链接并发，仍服从 `parallel_jobs` 的总并发上限；设为正整数可单独限制同时运行的链接任务数。
4. 如需 LTO，勾选 **`build_lto`**；默认只构建普通版本。
   如果已有启用 LTO 时生成的普通包，可在 `native_run_id` 填入其 Actions run ID，复用普通包、源码 commit 和静态依赖；留空则重新构建普通版。复用时 `build_type` 必须匹配，源码以该普通包的记录为准。
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

`build-info.json` 包含源码、rpmalloc、vcpkg 和构建配置的 commit，以及实际 CMake 参数；合并包记录普通版和 LTO 的信息。

Arkari 的源码 checkout 不会被打包上传。中间 artifact 保存构建输出；最终工具链包附带 LLVM、rpmalloc 和 vcpkg 依赖的许可证。

## 许可

本仓库的构建脚本采用 MIT 许可证。Arkari / LLVM、rpmalloc 及其他依赖保留各自的许可证。
