# Arkari Builds

使用 GitHub Actions 构建 [SakuraFox-GC/Arkari](https://github.com/SakuraFox-GC/Arkari) 的 Windows x64 工具链。本仓库只保存构建配置，源码在 CI 中浅克隆；本地无需克隆 LLVM。

工作流**只有 `workflow_dispatch`**，不会因 push、PR 或定时任务运行。

## 手动构建

1. 打开 [Actions → Build Arkari for Windows](https://github.com/SakuraFox-GC/Arkari-Builds/actions/workflows/build-windows.yml)。
2. 点击 **Run workflow**，选择 Arkari 的分支、tag 或 commit；默认 `llvm-23.x`。
3. `parallel_jobs` 默认为 `0`，使用 runner 的 CPU 数。链接并行数固定为 `2`。
4. 成功后从该次运行的 **Artifacts** 下载工具链 `.7z`、SHA256 和 `build-info.json`。产物保留 14 天。

也可手动使用 GitHub CLI：

```sh
gh workflow run build-windows.yml --repo SakuraFox-GC/Arkari-Builds \
  -f arkari_ref=llvm-23.x -f parallel_jobs=0
```

默认使用 `windows-2025`，自动选择 runner 已安装的 Visual Studio x64 开发环境。完整 LLVM 构建可能耗时数小时；单次 job 的超时为 360 分钟。

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

`vcpkg.json` 固定 vcpkg baseline，工作流从同一 commit 拉取 vcpkg 并缓存二进制依赖。`libLZMA` 的 vcpkg port 名称实际为小写 `liblzma`。更新 vcpkg 时修改 manifest 的 `builtin-baseline` 即可。

以 runner 预装的 clang-cl / lld-link / llvm-lib 引导构建；`llvm-tblgen` 从本次源码编译，避免复用其他 LLVM 版本的生成器。DIA SDK 由 VS 安装目录定位，不使用本机路径。配置中的 Zlib / libxml2 / LZMA 为必需依赖；未请求的 Zstd 支持关闭。

安装后会验证 clang、lld、lldb、clangd 能启动，使用 `/MT` 编译并运行 C++ 程序，生成 x64 / x86 / AArch64 对象，并编译和运行 OpenMP 程序。`build-info.json` 包含源码、rpmalloc、vcpkg 和构建配置的 commit，以及实际 CMake 参数。

源码不会被上传为 artifact。工具链包附带 LLVM、rpmalloc 和 vcpkg 依赖的许可证。

## 许可

本仓库的构建脚本采用 MIT 许可证。Arkari / LLVM、rpmalloc 及其他依赖保留各自的许可证。
