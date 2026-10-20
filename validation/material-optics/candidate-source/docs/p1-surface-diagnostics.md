# P1：Surface 契约与诊断通道（研究原型）

## 当前边界

工作树：`research/glass-health-core`，基于 P0 提交 `8ea06bf`。本轮改动仍未提交／推送。没有安装 deb、连接目标设备、修改设备偏好或重启 SpringBoard／Backboardd。

**已实现的是共享描述契约、生产者状态一致性，以及只读诊断接收；不是逐玻璃渲染 consumer，也不是 iOS 26 Liquid Glass 效果验收。**

## 已落地

- `LGSurfaceDescriptorV1`：152-byte 固定宽度、无指针 ABI。描述角色、形状／mask 的坐标和来源、几何／appearance／interaction generation、capture owner、嵌套策略及 profile／quality metadata。
- 校验拒绝未知版本／flags／reserved、NaN／Inf、负尺寸、越出所属 bounds 的有效 mask、不合法触摸坐标、旧 owner 与倒退 subgeneration；同代 geometry／appearance／interaction 不得偷偷改变。
- Registry 在 descriptor 接受后才提交 owner；首次记录保存 prefix，重复登记保持 generation。显式销毁路径退休绑定；weak 材料 owner 消失与独立 nil owner 区分。普通 Passcode `UIView` tint 保留原有 disable／restore 登记，但不进入玻璃契约。
- 快照查询不创建记录、不修补 owner、不提交 generation。未同步布局与 stale owner 直接拒绝；CA filter readback 的 stock visibility 门控与诊断解耦，仍不能证明屏幕呈现。
- Shape 由统一写路径更新：显式矩形、实际路径与 glyph／image producer mask 区分；QuickActions 几何变化递增 geometry generation，而非错误递增 appearance。
- Alert／Clock／CoverSheet／QuickActions 已写入契约；共享 registry 同时允许其他现存玻璃 host 的描述。没有宣称所有 host 的交互／形状 producer 都已完备。

## 诊断传输

开关：`Surface.Diagnostics.Enabled`，缺失或非 NSNumber 均关闭；本轮没有启用它。只有 SpringBoard 可发布。

包为 56-byte header + 最多 128 个 160-byte entry，固定总长 **20,536 bytes**。启用后每秒主线程取值、串行 IO 队列原子替换文件，再发 Darwin 通知；仅允许一个进行中的写任务。每次启用生成新 producer epoch。

路径：`/var/mobile/Library/Accessibility/liquidglass-surface-diagnostics-v1.bin`。

Backboardd 在独立队列只读验证长度、文件类型／UID／权限、epoch／serial、5 秒 freshness、排序 ID 和每个 descriptor。通知入口原子合并，关闭时不入队；消费后立即释放包，仅保留 replay 游标及日志摘要。启动清理保留正式文件，只清除匹配实际临时文件格式且超过五分钟的遗留文件。

实跑并发测试发现并修复：原子替换可能令读端已打开的旧 inode `nlink==0`；这是完整旧快照，不该误拒绝。多硬链接仍拒绝。未用 mmap／seqlock，写者崩溃不会留下等不到结束的 odd sequence。

**安全限制：** UID／权限不等于 producer 身份认证，同 UID 仍可伪造。接收结果不写 uniforms、不控制 material hiding、不影响 render dispatch，不是 GPU／present ACK。

## 本地验证

```sh
python3 scripts/test_surfaces.py
python3 scripts/check_surfaces_sdk.py
SURFACE_ARCH=arm64e python3 scripts/check_surfaces_sdk.py
git diff --check
```

Linux 测试编译并执行真实 C 生产校验器／原子 IO，包括恶意几何、触摸、flags、owner／subgeneration、包越界／截断、新鲜度／重放／epoch、symlink／FIFO／权限／硬链接及并发 atomic snapshots。源码 guard 另验证诊断不进入 render callbacks、query 不绑定、CA readiness 独立和普通 UIView 生命周期兼容。

iPhoneOS 16.5 SDK 下对 LGGlassKit、LGLiveBackdropView、四宿主 hooks 和完整 Backboardd Tweak.mm 做 arm64／arm64e **语法验证**；仅见既有 `UIApplication.windows` 弃用警告。这不是链接成功、完整 Theos package、安装或运行时／最终像素验证。

## 尚未解决的关键链路

1. render callback 的 `layer` 是尚未解码的私有 `void *`；当前静态证据没有证明可安全读取 UIKit `groupName`，也没有建立它与单个 producer surface 的稳定关联。
2. filter atom 只代表 host／filter 类型，多个玻璃实例会共享；不可用 atom、尺寸或跨进程指针套用某个实例的 bounds、mask 或触摸数据。
3. profile／quality 目前仅 metadata，未映射新的 Metal material／quality budget；nested policy 也未完成跨实例 capture-owner 仲裁。
4. 逐实例 consumer、渲染完成／呈现证据与真机验收均待完成。不得以诊断包被接受或 CA filter attached 代替这些证据。
