target triple = "x86_64-pc-windows-msvc"

declare void @llvm.localescape(...)
declare i32 @callee(i32)

define i32 @escaped(i32 %a) {
entry:
  %slot = alloca i32, align 4
  call void (...) @llvm.localescape(ptr %slot)
  store volatile i32 %a, ptr %slot
  %b = load volatile i32, ptr %slot
  ret i32 %b
}

define i32 @tail(i32 %a) {
entry:
  %r = musttail call i32 @callee(i32 %a)
  ret i32 %r
}
