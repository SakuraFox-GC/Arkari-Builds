# Arkari Builds

使用 GitHub Actions 构建 [SakuraFox-GC/Arkari](https://github.com/SakuraFox-GC/Arkari) 的 Windows x64 工具链。本仓库只保存构建配置，源码在 CI 中浅克隆；本地无需克隆 LLVM。

入口工作流**只有 `workflow_dispatch`**，不会因 push、PR 或定时任务运行。

## 手动构建

1. 打开 [Actions → Build Arkari for Windows](https://github.com/SakuraFox-GC/Arkari-Builds/actions/workflows/build-windows.yml)。
2. 点击 **Run workflow**，选择 Arkari 的分支、tag 或 commit；默认 `llvm-23.x`。
3. `parallel_jobs` 默认为 `0`，使用 runner 的 CPU 数。链接并行数固定为 `2`。
4. 如需 LTO，勾选 **`build_lto`**；默认只构建普通版本。
5. 成功后从该次运行的 **Artifacts** 下载工具链 `.7z`、SHA256 和 `build-info.json`。产物保留 14 天；LTO 合并包名称包含 `ThinLTO`。

也可手动使用 GitHub CLI：

```sh
gh workflow run build-windows.yml --repo SakuraFox-GC/Arkari-Builds \
  -f arkari_ref=llvm-23.x -f parallel_jobs=0 -f build_lto=true
```

Runner 镜像通过仓库的 Actions Variable **`WINDOWS_RUNNER_IMAGE`** 配置，可在 [Settings → Secrets and variables → Actions → Variables](https://github.com/SakuraFox-GC/Arkari-Builds/settings/variables/actions) 修改；未配置时使用 `windows-2025-vs2026`。工作流自动检测已安装的 Visual Studio x64 开发环境。完整 LLVM 构建可能耗时数小时；单次 job 的超时为 360 分钟。

## ThinLTO 两阶段构建

启用 `build_lto` 后会串行运行两个独立 job，各有 360 分钟限额：

1. **Native toolchain**：使用 VS 随附的 LLVM 构建普通 Arkari，保留原生库，并提供下一阶段的 Arkari、`llvm-tblgen` 和静态依赖。
2. **ThinLTO binaries with native libraries**：使用第一阶段的 Arkari，以 `LLVM_ENABLE_LTO=Thin` 构建同一源码。只将第二阶段的 `bin` 覆盖到普通工具链，保留普通版的 `lib`、头文件和资源目录。

第二阶段固定第一阶段的 Arkari / rpmalloc commit，并直接复用第一阶段的静态依赖。合并前检查普通 DLL 的导出在 LTO DLL 中仍然存在，合并后验证普通库文件的 SHA256 未变化。随后使用 MSVC 链接普通版 `libclang.lib` 并加载 LTO DLL，检查混合分发包的兼容性。

普通包和最终 `ThinLTO` 合并包都会保留。普通 artifact 中的 `bootstrap` 目录仅用于两个 job 之间传递构建依赖，不需要随工具链解压。

## 构建内容

| 项目 | 配置 |
| --- | --- |
| 构建类型 | Release，静态 CRT (`MultiThreaded` / `/MT`) |
| LLVM 项目 | clang、clang-tools-extra、lld、lldb |
| 代码生成目标 | X86（x86 / x64）、AArch64 |
| Runtimes | compiler-rt、OpenMP；关闭 compiler-rt ORC |
| 分发组件 | 沿用提供的 `distribution` 组件列表，见 `scripts/Build.ps1` |
| 分配器 | 单独浅克隆 `mjansson/rpmalloc` 的 `develop` 最新提交 |
| vcpkg | `zlib`、`liblzma`、`libxml2`，均为 `x64-windows-static` |
| LLDB | 禁用 Python，启用 LZMA / libxml2 |

`LLVM_ENABLE_RPMALLOC=OFF`，并将 `LLVM_INTEGRATED_CRT_ALLOC` 指向外部 rpmalloc，避免被 in-tree rpmalloc 覆盖。每次构建记录 rpmalloc 的确切 commit。

直接复用镜像预装的 vcpkg（`VCPKG_INSTALLATION_ROOT`，当前为 `C:\vcpkg`），无需 clone 或 bootstrap。`vcpkg.json` 声明三个静态依赖，依赖版本跟随镜像预装的 ports；实际 vcpkg commit 写入构建信息，并用于区分二进制缓存。`libLZMA` 的 vcpkg port 名称实际为小写 `liblzma`。

以 Visual Studio 随附的 clang-cl / lld-link / llvm-lib 引导构建（当前镜像为 LLVM 22.1.3，兼容 VS 2026 STL）；`llvm-tblgen` 从本次源码编译，避免复用其他 LLVM 版本的生成器。DIA SDK 由 VS 安装目录定位，不使用本机路径。配置中的 Zlib / libxml2 / LZMA 为必需依赖；未请求的 Zstd 支持关闭。

安装后会验证 clang、lld、lldb、clangd 能启动，使用 `/MT` 编译并运行 C++ 程序，生成 x64 / x86 / AArch64 对象，编译和运行 OpenMP 程序，并通过 MSVC 链接、运行 libclang 程序。`build-info.json` 包含源码、rpmalloc、vcpkg 和构建配置的 commit，以及实际 CMake 参数；合并包记录两个阶段的信息。

源码不会被上传为 artifact。工具链包附带 LLVM、rpmalloc 和 vcpkg 依赖的许可证。

## 许可

本仓库的构建脚本采用 MIT 许可证。Arkari / LLVM、rpmalloc 及其他依赖保留各自的许可证。
