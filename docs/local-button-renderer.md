# 同进程局部按钮材质接口：有限背景源域

## 本体与启用边界

这仍是 LiquidAss 的原有候选代码，不是新插件。`LGLocalButtonMaterialView` 作为44×44pt控制的非交互 sibling，保留原控制的命中、尺寸、target/action和前景。编译门禁默认0，还需显式opt-in、有效的源provider和eligible state；失败只隐藏本地材质，原CA/current/native路径不能因此被隐藏。

Provider只允许交付它实际拥有的同进程MTLTexture。这里不提供系统截图、窗口遍历、IOSurface或跨进程背景捕获。`LiveAppOwnedTexture`是来源声明，不等于系统背景；静态图/合成色必须另开approximation许可并如实报告。没有可信背景源时，不得以色彩图替代后声称系统玻璃已经接通。

## 真实坐标与采样域

- 目标永远为44×44pt，触点始终归一化在目标局部坐标中。
- 默认源域等于目标域，保持原来的纹理尺寸，包括旧合同可接受的131/132/133px边界。不能把133px改成132px、把整张大背景缩成目标图。
- 外扩需provider明确设置`sourceOverscanEnabled`。源域包含目标，四边额外范围分别在0…16pt以内，源域最大76pt。原位移cap仍由目标短边的7/36决定，不随捕获范围增大。
- 新外扩源的texture extent必须精确匹配sourceRect×pointScale（仅0.001px数值误差）；目标像素边长须为整数。允许明确的fractional-pixel ROI origin，按精确pointScale映射，不暗自round；源的实际像素范围必须完整容纳目标。极小但实际非零margin不能被忽略，不清楚捕获像素定义则拒绝。
- `LGLocalSourceMapping.inc`是C与MSL共用的一份坐标转换。主体折射和源平面环境坐标保留原有限raw offset，外扩时才将目标坐标加ROI origin并除实际source大小；**最终**half-texel clamp落在真实源边界，不能先夹在44pt按钮内。
- 输出drawable仍按目标尺寸。原本体layer圆形裁剪不变，外扩纹理不能画成大方片。新fragment输出域外透明，目标形状外保持对应原背景ROI，不扩大命中区。

## ABI、触点与生命周期

原Backboard的208B ABI不变。局部renderer原224B contact前缀后再加ROI origin和overscan gate，成为240B；offset/size有C及C++断言。224B旧缓冲如需提升，必须调用明确的零尾部promotion函数，不能把224B直接交给读取240B的shader。

沿用一份主体/触点高度、法线、Snell和有界源平面色光公式，没有添加固定灯或彩色蒙层。press/drag只消费原状态机的有效点；release/cancel保点随pressure衰减，idle/disable/reset归零。源域扩大不改变触点中心。

100ms源期限、owner/frame/target代际、immutable texture lease、zeroing-weak同帧身份和完整descriptor比较均保留。重复帧不能换纹理、换源rect/overscan标记或重贴时间戳。源失效/后台/离窗/命令失败只停本地层；正常完成释放lease。默认无常驻displayLink和轮询，只有原来的单次源过期timer。

## 验证结果及不可外推项

Mac Actions run38842648759：C数值、Apple Metal编译和真实MetalGPU通过。只改变源域中目标外的像素，目标ROI保持逐byte相同，实际GPU输出2026个内部像素变化，形状外变化0；命名边缘像素变化25色阶。冻结旧224B shader与新240B无外扩在44/131/132/133px、有效contact/无contact/zero-pad opt-in都逐byte一致。

原获准App build21实际类生成31项通过报告：228px源域→132px目标、origin48px、touch(.25,.5)不移位、位移cap25.6667px不变、回到旧crop仍完成GPU提交，原所有源失效/身份负控保留。

这些输入仍是自有静态纹理和合成state，不是真实UIKit系统host/屏幕像素验收；当前没有system-live provider。自然背景整体体积仍弱、右缘有尖色块，**视觉门槛未接受**。外扩因果成立不是iOS26材质parity证明。所有编译、链接、Metal执行只在GitHub Actions macOS/Xcode，本地Python只做source/文字/哈希和原图审核。
