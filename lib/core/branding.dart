/// 品牌与文案常量 —— **用户可见名称的唯一来源**。
///
/// ## 为什么要有这个文件
///
/// V5 要求「所有用户可见的品牌名称统一」，但品牌名此前散落在
/// 十几处（`MaterialApp.title`、侧栏 logo、登录页页脚、启动页、
/// Android `android:label`、`strings.xml`、通知渠道名、
/// `MusicServerProvider.label`、手机遥控网页 …）。
/// 散落的字符串一定会再次漂移，所以收敛到一处常量。
///
/// ## 改名时的注意事项（重要）
///
/// 改 [kAppName] 只影响**显示**。以下这些**刻意不改**，否则会破坏
/// 既有安装的登录态、收藏与历史，或让 NAS 侧对不上：
///
/// | 项目 | 值 | 原因 |
/// |---|---|---|
/// | Android `applicationId` / 包名 | `com.feiniu.tv.music` | 改了就是另一个 App，无法覆盖升级，用户数据全丢 |
/// | `MainActivity` 的 `feiniu/boot` MethodChannel | 不变 | 与 Kotlin 侧约定，改名要同步两端 |
/// | `secure_store` 的存储键前缀 `feiniu.` | 不变 | 改了等于清空收藏/历史/偏好 |
/// | 飞牛 API 路径与请求参数 | 不变 | 由 NAS 侧契约决定 |
///
/// 也就是说：**本版是覆盖安装**，收藏、最近播放、播放模式、歌词手动选择
/// 与布局偏好都会保留（见 `LocalLibraryRepository`）。
library;

/// 产品显示名。所有用户可见位置都必须引用它。
const String kAppName = 'XX音乐';

/// 版本号。
///
/// ⚠️ **必须与 `pubspec.yaml` 的 `version:` 保持一致**（形如 `0.2.0+2`，
/// `+` 前是 versionName、后是 versionCode）。这里手工同步而不用
/// `package_info_plus`，是为了不引入新依赖 —— 诊断页需要展示它，
/// 而它只在诊断页出现，手工同步的成本低于多一个原生插件的风险。
const String kAppVersion = '0.2.0+2';

/// 启动页/侧栏的副标题（描述性，非品牌名）。
const String kAppTagline = '客厅音乐播放器';

/// 手机遥控网页的标题与页面内标题。
const String kRemotePageTitle = '$kAppName · 手机遥控';
