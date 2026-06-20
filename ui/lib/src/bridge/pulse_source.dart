/// PulseSource 是 UI 与"用量来源"之间的抽象边界。
///
/// v1 用进程内 FFI([FfiPulseSource]);未来若改成本地辅助进程(HTTP),
/// 只需替换实现,UI / 模型层不动。
abstract class PulseSource {
  /// 用 JSON 配置初始化底层引擎。失败抛异常。
  void init(String configJson);

  /// 开始后台轮询。
  void start();

  /// 停止轮询。
  void stop();

  /// 触发一次强制回源(accountId 传空串=全部)。
  void refresh(String accountId);

  /// 读取当前快照(JSON 数组字符串)。便宜、可频繁调用。
  String snapshotJson();

  /// 按维度(account/api_key/model/user/group)取某实例最近 hours 小时的
  /// 用量序列 JSON([]Series)。本地 SQLite 查询,便宜。
  String chartSeriesJson(String instance, String dimension, int hours);

  /// 告知引擎弹层是否打开(打开则提频)。
  void setForeground(bool open);
}
