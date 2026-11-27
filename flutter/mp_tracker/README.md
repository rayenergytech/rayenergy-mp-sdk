# MP Flutter 埋点 SDK

SDK 自身版本见 [VERSION](../../VERSION)，更新记录见 [CHANGELOG](../../CHANGELOG.md)。运行时查询：`mpSdkVersion`。下载包根目录提供 `SDK-MANIFEST.json`；版本号不是应用构建号 `versionCode`，更新时使用同包配套源码。


适用于 Flutter iOS、Android、Web；基于 Dart 实现，同中台现有三端 SDK 使用相同采集协议。完整安装、示例、字段口径及验收步骤见仓库 [Flutter端接入文档](../../../docs/Flutter端接入文档.md)，后台「功能与对接文档 → Flutter 埋点」也提供同一文档。

## 快速接入

```yaml
dependencies:
  mp_tracker:
    git:
      url: https://github.com/rayenergytech/rayenergy-mp-sdk.git
      path: flutter/mp_tracker
      ref: v1.5.11 # 选择已发布并验收的标签
```

```dart
import 'package:flutter/material.dart';
import 'package:mp_tracker/mp_tracker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 应用取得用户隐私同意后初始化；不是在构建 Widget 时重复初始化。
  final tracker = await MpTracker.initialize(MpTrackerConfig(
    appKey: '后台签发的 appKey',
    endpoint: 'https://collect.example.com', // 采集网关域名，不含 /api/v1/track/collect
    commonFields: {'channel': 'google_play', 'campaign': 'spring'},
    onError: (error, stack) => debugPrint('埋点异常：$error'),
  ));
  runApp(MaterialApp(
    navigatorObservers: [tracker.navigatorObserver()],
    routes: {'/': (_) => const Scaffold(body: Text('首页'))},
  ));
}
```

`await tracker.track('pay_button_click', description: '点击支付按钮', params: {'sku_code': 'vip_month'});`

`tracker.setUserId('123');` 登录后关联用户；`tracker.setUserId(null);` 退出登录清理用户。

`await tracker.flush();` 主动发送；`await tracker.dispose();` 释放观察器、定时器与网络资源。

## 运行检查

Flutter >=3.29 / Dart >=3.7，Android Java17、compileSdk >=34、AGP >=8.3、Gradle >=8.4；iOS >=12（最终要求以项目解析到的插件和工具链为准）。

```sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test example/lib
flutter analyze
flutter test
```

SDK 不自动收集广告标识、地理定位或账号归属国家；权限或环境不允许的字段不伪造。系统强杀及浏览器关闭时不能保证立即发送，已持久化事件留待下次初始化重传；网关接受不等于最终落库或全链路恰好一次处理。


## 统一业务客户端 MpClient

初始化埋点 SDK 后创建同包 MpClient，使用原 tracker 的设备 ID。提供 loginGuest、setSession、getUserInfo、refresh、logout：loginGuest 返回整套配置；正式登录可用 loginIdentity/loginPassword，绑定用 bindIdentity；refresh 成功会把 user_id、ab_snapshot、config_version 绑定到后续事件，退出／换号清理上下文，丢弃旧会话异步响应。Token 默认持久化，并在同 APP/API/客户端/安装作用域初始化时恢复；hasSession 可判断是否已恢复。原生端在主线程调用；Web／Flutter 为 Promise／Future，Android／iOS 为 Result 回调。初始化传 apiBase、appCode、整数 versionCode，有支付展示时传 paymentChannel；Android／iOS 自动确定实际端，Flutter 读取 tracker 运行端，Web 构造参数 platform=3。channel 应在采集器 commonFields 中首次设置；language、adGroup、adCreative 可通过 contextFields（Web 使用初始化选项）传入；旧 country 参数仅兼容保留，不定义用户国家。SDK 不自动进行原生购买，普通失效会话不自动转游客；明确注销状态 40108 的自动恢复见下文。

客户端主文档为仓库 docs 中《客户端数据上报与SDK》《客户端整套配置字段说明》。原有埋点初始化方式保持兼容，不升级业务封装也不影响旧事件上报。新增原生业务代码需在对应 Android／iOS／Flutter 工具链与测试 APP 验收；Web 模拟网络测试不能替代真机测试。


返回配置怎么取、怎么处理错误，请看[四端取值示例](../../../docs/客户端数据上报与SDK.md)及[完整响应与字段对照](../../../docs/客户端整套配置字段说明.md)。SDK 的 loginGuest／refresh 已解包 data；getUserInfo 直接返回用户对象。


云控 schemaVersion=3（云控沿用 v2 结构） 的 `cloud.fields` 直接返回“字段名 → 值”，例如 `{"homeTabUi":"0"}`；不再返回参数名称包装。业务取值时移除旧的 `["参数1"]` 这一层，值本身的类型不变。


## Invalid cookie date 排查

登录或 refresh 在 dart:io 内报 Invalid cookie date 时，检查服务端 Set-Cookie 的 Expires。中台公共响应层已将偏移时区日期转换为 GMT，并保持实际到期时刻、有效期及安全属性。示例 `Thu, 19 Nov 2026 14:14:01 +0800` 应输出为 `Thu, 19 Nov 2026 06:14:01 GMT`；更新服务端后重试，无需修改 MpClient 的 JSON 解析或关闭调试／TLS。


原生端商品读取：iOS/Android 的 paymentOptions 和渠道商品 ID 只需客户端关联与 SKU 渠道绑定有效，支付配置未填写、未启用或已停用也会返回；Web 仍要求启用渠道。服务端下单、支付核验和回调继续校验支付配置。

整套配置 schemaVersion=3：会员／商品页使用 pageCode/pageName；商品只保留《客户端整套配置字段说明》中的固定字段，购买标识统一读取 paymentOptions[].channel 与 paymentOptions[].channelProductId，每项只有这两个字段。商品不再返回渠道 ID 别名、channelConfig、强制付费或赠送展示字段；强制付费读 membershipPlan.forcePayment。旧客户端读取 slot/slotName、商品 externalProductId/storeProductId 等的代码须同步调整。

## Token 持久化与恢复

`loginGuest()` 成功和 `setSession(accessToken)` 会自动保存 Token。新建 MpClient 自动恢复同一作用域的 Token，使用 hasSession 判断后直接 refresh 获取服务端配置；不会缓存会员权益、用户资料或 AB 分组。作用域同时包含 API 地址、appCode、真实客户端和 deviceId，改变其中任一项不会复用旧登录。关闭自动初始化后，首次无 Token 的游客流程才手动调用 loginGuest；正式账号可使用 loginIdentity/loginPassword，游客升级使用 bindIdentity；外部直接登录后仍可 setSession。不要每次启动都无条件 loginGuest 覆盖正式会话。

Web 使用同源 localStorage；Android 使用 AndroidKeyStore 保护的 AES-GCM 缓存（API21/22 采用 RSA 包装 AES 密钥）；iOS 使用安装作用域的 Keychain；Flutter 使用 flutter_secure_storage，原生端为平台安全存储，Web 需 HTTPS/localhost。Flutter 初始化后先 await client.ready 再读取 hasSession，setSession/clearLocalSession 返回 Future<void>，logout 返回游客配置 Future，均需 await。Flutter 应执行 flutter pub get，并按插件说明排除 Android 的安全存储备份恢复冲突，见 [flutter_secure_storage 9.2.4 文档](https://pub.dev/packages/flutter_secure_storage/versions/9.2.4)。

logout 请求服务端撤销当前正式会话并返回游客、保存新 Token 和重新获取配置；allDevices=true 撤销全部客户端会话。clearLocalSession 仅清本地缓存，不撤销服务端 Token。退出不注销账号、不取消商店订阅。HTTP401、业务40101，以及账号停用/合并40302 会清理本地会话并报错；普通40301、断网、超时和服务端500错误不清理。SDK 不自动把普通失效或封禁会话改为游客；明确注销状态 40108 按下文自动恢复。SDK 不自动延长 Token 的服务端有效期。close（Web/Flutter）仅释放实例，不删除已保存 Token；退出账号应显式 logout。

存储失败通过 sessionStorageError 报告，当前进程可继续使用内存 Token；存储不可用时不能保证重启恢复。不要把 Token 放入埋点参数、公共字段或日志。原生与 Flutter 源码需要在对应工具链和真机验收；Web 测试不能替代此检查。


## 统一账号接口

本版本 logout 是服务端退出并返回游客：Web/Flutter 使用 await，iOS/Android 使用 completion/callback。旧的本地清理使用 clearLocalSession。bindIdentity 保留原用户ID，deleteAccount 返回注销回执并清本地状态，APP 再显式 loginGuest 恢复未注销的本机原游客；原游客自身已注销或没有原游客时才新建ID；getAccount 或配置 user.account.sessionType 才代表正式登录状态，hasSession只说明有Token。详见[统一账号接入](../../../docs/账号体系与接入.md)。

### 支付环境

`MpClient` 支持可选初始化参数 `paymentEnvironment`（`production`／`sandbox`），默认 `production`，业务请求自动携带 `X-Payment-Environment`。沙盒订单、权益和订阅不影响正式账本；直接调用支付 HTTP 接口时也须传同一请求头。详见仓库 `docs/支付与订阅对接.md` 的双环境升级说明。用户身份和商品基础配置仍共享。


## 设备标识与重装恢复（2026-10-26）

同一 APP/deviceId 复用游客；注销只清除被删账号的恢复关联。游客100切换到账号200后注销200，仍恢复100；注销100自身时才创建新游客。Android 新安装使用稳定的 ANDROID_ID 标识，升级保留旧 UUID，并通过游客登录或已登录游客的配置刷新登记 recoveryId；重装可恢复原游客 userId。Flutter iOS 将原队列的设备 ID 迁移到本机 Keychain，设备标识和 Token 安装作用域分开；Flutter Android 使用同一 Android 恢复协议。Web 保留同源存储，存储不可用时初始化失败，不再静默生成临时 ID。

先升级中台再升级 SDK。Android 旧用户需在卸载前成功使用一次新版游客登录或配置刷新；已丢失的旧版随机 ID 无法找回。正式账号必须通过正式身份登录；设备标识不是正式身份凭据，关联冲突不自动合并。iOS 系统清理/设备抹除、Android 恢复出厂或签名/系统用户变化、浏览器清理网站数据等情形无法保证标识保留。

Flutter 需要 `flutter pub get` 并完整重建（新增 android_id 0.4.0）；设备/Keychain 暂不可读会终止初始化并报错，解锁或恢复环境后重试。详见文档中心“SDK：下载、四端接入与返回读取”的设备标识章节。Android/iOS/Flutter 的新增测试仍需在对应工具链及真机完成验收。

## 业务系统登录与续期

新增 `loginBusiness`（参数为 connectionId、宿主 exchangeTicket 回调）、`renewSessionForBusiness` 和 `onSessionChanged`。保留原 businessTicket。loginBusiness 仅向宿主交换回调传一次性 ticket，宿主通过HTTPS调用自己的 `/api/v1/auth/login`；SDK不会将中台Token或服务端凭据发送给业务端，也不持久化业务Token。结果由宿主安全保存。交换途中换号／退出会丢弃结果。

同一实例的并发 renewSession 合并为一次中台续期。推荐 `renewSession → loginBusiness → 保存业务Token`；renewSessionForBusiness 是便捷的“续期后取票据”方法，返回票据，宿主仍须兑换成业务Token。多实例／多标签页的续期需要宿主统一协调。

onSessionChanged 在Token切换／清理时调用，宿主立即清理旧业务凭证和用户缓存，回调只做本地清理。Android/iOS 主线程调用，交换回调结果由SDK回主线程处理。不要在回调内再次登录或续期。Android/iOS使用Result回调，Web使用Promise，Flutter使用Future。

游客业务登录默认关闭，需主管理员按连接开启。业务绑定到期使用服务端 sessionExpiresAt，票据单次使用且60秒有效；兑换响应丢失需申请新票据。业务接入不支持请求切换支付沙箱，测试需独立部署。完整接口、服务端示例及升级约定见仓库 docs/业务系统接入流程.md。

规则字段与埋点的五项共享映射、setRuleContext 的更新／清空方式及 refresh 调用顺序，见[规则字段与埋点共享取值](../../../docs/SDK分端接入与下载.md#规则字段与埋点共享取值)。


## 1.2.0：Google游客升级或登录已有账号

新增 `loginOrBindIdentity(proof)`，参数为 `provider: google`、`credential: 官方ID Token`、`nonce: 中台challenge原值`。前置为有效游客会话及 `oauthChallenge` 后带nonce的Google官方授权。未绑定则保留游客ID升级，已绑定则登录已有账号，不合并数据。返回登录字段及 `action`、`accountSwitched`、`configuration`、`configurationRefreshRequired`；配置暂时失败只重试refresh，不重复授权。SDK自动更新Token和埋点身份、清理旧实验/配置；宿主负责更新自己的业务会话及用户缓存。旧loginIdentity/bindIdentity不变。

详见 [完整接口及各端示例](../../../docs/Google游客升级与账号切换.md)。Google官方登录仍由宿主接入。


## 1.3.0：同一用户的受限游客恢复（可选）

```dart
final client = MpClient(
  tracker: tracker, apiBase: 'https://api.example.com', appCode: 'my-app',
  guestRestoreMode: 'same_user_restricted',
);
```

仅接受 `guestRestoreMode: 'same_user_restricted'`；省略或传 null 沿用旧行为。该配置随游客登录、账号身份操作和退出请求发送，调用方 proof 中的同名字段不能覆盖配置，也不能在未配置时启用。存储键和安装 deviceId 不变。

启用后，所有返回新 Token 的账号操作必须回显相同的 `guestRestoreMode`；旧服务端缺少回显或回显不符时明确报 `Unsupported guest restore mode`，保留当前 Token，不接受未协商的身份。`getAccount()` 返回的账号信息和 `loginOrBindIdentity()` 返回结果可读取回显字段。

Google 绑定后退出可返回相同 userId 的 `sessionType=guest` / `loginMethod=guest` 会话，`accountType` 仍可能是 `registered`。只能按 `sessionType` 判断正式认证，不能依据 userId、accountType 或 Token 存在显示正式权益。正式资料、订单和权益仍保存在服务端；受限游客需要重新授权才能访问。`40307 authentication_required` 不清除有效游客 Token，宿主应引导重新授权，不能显示为“从未购买”。

再次 Google 授权的统一入口可返回 `action=account_reauthenticated`、`accountSwitched=false`（仅启用模式时接受）；原有 `guest_upgraded` 对应 `accountSwitched=false`，`existing_account_login` 对应 `accountSwitched=true`，含义不变。所有结果先校验再替换 Token。退出与重新认证继续刷新 runtime 配置并触发 `onSessionChanged`。宿主应在该回调清除旧业务登录态、资料和权益缓存，随后按当前 sessionType 重建展示；需要正式业务会话时重新获取业务票据并验证认证状态，不能仅凭相同 userId 恢复旧业务 Token。

切换到既有 Google 账号仍不合并数据；退出目标由中台可信安装关系决定。此模式需要支持协商的新版中台，不会猜测补建历史已丢失的游客关联。


### Google正式会话直接注销（服务端按APP启用）

现有 `deleteAccount(proof)` 可透传 `verificationMode: "session"` 与 `confirmation: "DELETE_ACCOUNT_AND_ACKNOWLEDGE_SUBSCRIPTIONS"`；SDK自动携带中台当前Token、deviceId及Android recoveryId，成功后清本地会话并返回原注销回执，不自动注册游客。无需新增SDK方法或升级版本。服务端首批仅启用 `app_1756b4497135`，以预检查 `sessionVerificationAvailable` 判断当前能力；不传mode继续原再次验证流程。普通/受限游客、非Google正式会话及无效会话不可使用。宿主仍需展示订阅影响并确认、保存回执、清理业务会话，再显式 `loginGuest`。完整字段及Flutter示例见仓库 `docs/账号体系与接入.md` 的“可选Google当前会话验证注销”。

注销恢复规则：`guestRegistrationRequired=true` 表示需重新建立游客会话，并非必须新建用户。服务器按Token注销当前账号，保留不属于注销主体的本机原游客及Android恢复关联；原游客已绑定另一身份时仍按受限游客策略访问。宿主不得指定恢复userId。

## 1.4.0：只读用户国家与采集鉴权

用户国家读取服务端返回的 `ip_country`（ISO 两位码或 null），不需要初始化 country/country_code，也不能通过语言、地区、公共字段或 params 覆盖。服务端仅在首次建号时按可信 IP 采集，后续登录和游客升级保留原值；切号与退出读取对应账号。旧 country 参数与载荷继续兼容，已弃用于用户国家和国家条件。

MpClient 与 tracker 的 apiBase/endpoint 使用同一网关（忽略末尾斜杠）时，采集请求自动携带当前 Bearer 会话；Web directBaseUrl 使用共同继承的入口。不同地址或单独 tracker 继续匿名。服务端逐条核对会话 APP 与事件 user_id，仅可靠匹配时附加已保存的 ip_country，否则为 null；不会按采集当次 IP 猜测。

Token 只在发送时进入请求头，不写入离线事件。切号不改写历史事件 user_id；旧用户事件与当前会话不匹配时国家未知，重试保留原 event_id 及首次接收的国家快照。自定义适配可显式使用 setCollectionTokenProvider，且只能向可信入口提供当前 Token 或 null。Flutter 自定义传输可额外实现 AuthenticatedTrackerTransport，旧接口保持兼容。先升级中台，再升级 SDK。完整四端读取与兼容说明见仓库 docs/SDK分端接入与下载.md。


## 初始化性能与本地诊断（1.5.2）

无需修改现有初始化调用。包信息、设备信息、初始网络状态和偏好存储并行读取；设备与网络为非必要项，最多等待2秒，失败或超时不阻塞启动，不伪造字段值，超时的迟到结果不回写旧事件。网络监听仍可更新后续事件的网络状态。

包信息／偏好读取最多5秒，原生真实构建号缺失、不匹配仍报错；稳定设备ID读取最多5秒，读取失败不生成临时ID。持久化写入不强行超时，以免迟到写入覆盖身份或队列。此上限不代表整个初始化一定5秒内结束，关键写入和队列恢复仍需实际完成。

可选加入本地诊断，不配置不会自动打印或上传：

```dart
final tracker = await MpTracker.initialize(MpTrackerConfig(
  appKey: appKey,
  endpoint: apiBase,
  onTiming: (stage, elapsedMs, success) {
    debugPrint('$stage: ${elapsedMs}ms success=$success');
  },
));
```

阶段包括 `initialize.package_info`、`initialize.device_info`、`initialize.network`、`initialize.preferences`、`initialize.identity_read`、`initialize.identity_queue`、`initialize.total`、`client.session_restore`、`client.guest_login`、`client.runtime_config` 和其他请求的 `client.request`。只有阶段名、耗时及成功标志，不包含Token、userId、设备ID或请求体；HTTP阶段只计请求等待，不代表后续业务校验已成功。

仍先 `await client.ready` 再判断 `hasSession`，有会话 `refresh()`、无会话 `loginGuest()`；此次不自动切换账号、不跳过会员／支付核验、不使用缓存权益。60秒仅为默认事件等待身份的窗口，不是初始化等待时间。需要发布包含新版SDK的宿主APP后生效；Flutter真机插件耗时需结合这些回调验收。

1.5.3 起 Flutter Web 每批有效上限为50条，maxBatchSize 可设置更小值；配置100时Web按50发送，Android/iOS仍按100发送，离线缓存按同一规则拆批，不删除剩余事件。


### Web 游客登录前复用 ID（1.5.4）

Web / Flutter Web 的 `loginGuest()` 自动携带最小设备条件 `webContext`。配合新版中台，在同一 APP 下满足设备/多条件规则时直接复用已有游客 userId，不新增用户。客户端不需要传 IP 或目标用户 ID。原生 Android/iOS 请求保持原行为。匹配会话的配置 `user.account.identityReused=true`、`authenticationRequired=true`，用户 ID 可沿用，但不能据此恢复原资料、订单、会员、余额或旧业务 Token；敏感操作仍需身份验证。需先部署后端，再更新网页实际 SDK/Flutter Web 构建。完整规则与验收见仓库 `docs/Web多条件用户归因.md`。

## 注销后的自动游客恢复（1.5.5）

中台返回明确注销状态 `40108` 时，MpClient 自动为当前 APP / 设备 / 客户端申请新的游客 ID，再刷新配置。普通 HTTP 401、40101、40302 等不触发新用户注册。恢复失败仍报错，保留已撤销凭据仅用于后续重试；不会用它恢复旧账号。并发请求不会反复创建游客。

`refresh()` / `renewSession()` / `getUserInfo()` 完成后返回新游客数据。其他原请求不自动重放，抛出可识别的账号切换错误：Web 的 `code=40108, sessionRecovered=true`；Flutter 的 `MpAccountDeletedRecovery`；Android/iOS 的 `MpClient.AccountDeletedRecovery`。宿主应同步清理原业务登录、订单和会员缓存，敏感操作由用户重新发起；原本的 `onSessionChanged` 通知仍会触发。

先部署新版中台，再替换 SDK 文件或重新构建客户端。主动 `deleteAccount()` 成功返回回执的流程仍清理本地状态，不在注销确认完成时立即注册。历史注销已擦除的 Token 哈希无法还原，需要业务端显式游客登录一次。事件埋点独立上报不代替 MpClient 的会话校验；启动时仍应按已有流程调用 `refresh()`。

## 自动游客初始化（1.5.6）

先初始化埋点采集器，再创建 MpClient。默认 `autoGuestLogin=true`：正常读取本地会话后，无 Token 就自动调用 `loginGuest` 并获取配置，已有 Token 就验证配置并绑定用户 ID。仅创建采集器不注册用户；已有会话普通过期、封禁、APP 停用或本地存储读取失败，会在本次初始化中报错，不当成新安装。明确注销仍走 1.5.5 的新游客恢复。

Web 等待 `await client.ready`（默认自动流程返回整套配置）；Flutter 等待 `await client.ready`（完成后再调用业务接口）。Android 调用 `client.initializeSession { result -> ... }`，iOS 调用 `client.initializeSession { result in ... }` 获取完成通知；Web / Flutter 也可直接等待 `initializeSession()` 返回配置。自动与显式游客初始化共享正在执行的登录请求，不重复注册。

需要自行控制登录的业务传入 `autoGuestLogin=false`，继续使用原来的 `loginGuest` / `refresh`。正式登录或直接设置会话优先于尚未完成的自动游客请求；宿主显式接管时，Web `ready` 可返回 null，Flutter 的 `ready` 只代表自动任务已结束，宿主自行等待其登录流程。不要在自动初始化中无条件循环调用 `loginGuest`。

自动失败可读取 `initializationError`；Web / Flutter 可在构造参数传 `onInitializationError`，Android / iOS 可设置同名回调。网络失败不会自动无限重试，可显式 `initializeSession` 重试；本地存储故障应先修复缓存或由宿主显式登录。`hasSession` 只代表有 Token，不代表已完成初始化或拥有正式账号权益。

## 当前来源 channel 与首次归因（1.5.8）

SDK 对新事件及后续登录/配置请求上报当前明确传入的渠道。可通过初始化 commonFields、setRuleContext 或 MpClient.channel 提供；后续明确更新会生效。setCommonFields 是替换操作，省略 channel 会恢复为 organic；setRuleContext 是增量操作，channel=null/空白表示清除。缺省及 organic/web/ogannic/unknown/null/undefined 等占位值统一为 organic。

SDK 不再读取安装级首次渠道缓存来覆盖当前值。升级保留安装标识、登录会话和离线队列；已经排队的旧事件保持原渠道、时间、事件ID和内容，重试不会改写。不要通过清空本地存储来修复渠道，这会破坏原用户及安装身份。

首次用户渠道由中台决定：从建号起默认 7 天内，首次成功受理的非自然量来源写入 register_channel 并固定；窗口外不补写，已有非自然量不覆盖。登录/配置规则仍收到当前来源，数据分析的渠道继续读取用户主档的首次渠道。SDK 不自动读取 URL/UTM 或猜测广告来源，宿主必须实际传入来源；异步获取后应更新渠道，后续事件会携带新值，必要时刷新配置。

**重要：1.5.7 安装级锁定行为已修正。** 保留原 SDK 调用与服务器协议，但依赖“所有事件永远沿用安装首次渠道”的业务须改为读取中台用户 register_channel。先部署支持 7 天窗口的中台，再将实际业务站点/应用替换为 1.5.8；仅升级中台下载包不会替换业务端正在使用的 SDK。清理 CDN/脚本缓存时保留本地用户与事件缓存。旧版完全未上报的广告来源不能从 organic 反推，历史恢复须有独立证据并单独审计。

## 广告收入（SDK 1.5.9）

新增 `beginAdImpression` 和 `reportAdRevenue`，使用同次曝光句柄关联eCPM预估与收入回调，冻结曝光时身份；金额必须传十进制字符串及显式单位，不能重复换算。完整字段与各端示例见SDK下载包内的 `docs/广告收入接入与ROI口径.md`。
