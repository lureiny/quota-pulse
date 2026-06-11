/// 应用版本号——编译期由构建脚本通过 `--dart-define=QP_VERSION=...` 注入。
///
/// 取值优先级(构建脚本 `git describe --tags --always` 实现):
///   1. 正好在某个 tag 上            → `v0.3.0`
///   2. tag 之后又有提交            → `v0.3.0-2-gabc1234`(tag-距离-短SHA)
///   3. 无可达 tag(浅克隆/无 tag)  → 短 SHA `abc1234`
/// 未注入(本地 IDE 直跑 `flutter run`)→ 'dev'。
const String appVersion = String.fromEnvironment('QP_VERSION', defaultValue: 'dev');
