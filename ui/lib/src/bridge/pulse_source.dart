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

  /// 按维度(account/api_key/model/user/group)取某实例最近 hours 小时的图表数据 JSON
  /// ({series,coverageFrom,requestedFrom})。空串=取数异常。
  ///
  /// **异步**:它在 Go 侧走 SQLite 聚合,数据量大时单次可达数秒。以前这里是同步 FFI,
  /// 直接冻住 UI 主 isolate;现在实现方必须把它挪到后台执行。
  Future<String> chartSeriesJson(String instance, String dimension, int hours);

  /// 同 chartSeriesJson,但按**本地日**聚合最近 days 天(供热力图)。空串=取数异常。
  Future<String> chartDailySeriesJson(String instance, String dimension, int days);

  /// 取某实例的覆盖水位与全历史最早事件 JSON({coverageFrom,earliestEvent}),
  /// 供热力图判断补齐进度/年份列表。空串=取数异常。
  ///
  /// 这个也**必须**异步:它在 Go 侧读 CoverageFrom + MinCreatedAt,而 usage 库是
  /// 单连接串行的 —— 留在主 isolate 就会排在那条几秒的聚合后面,等于白改。
  Future<String> coverageJson(String instance);

  /// 每实例的数据版本号 JSON:{"实例名": 版本号}。只在该实例的图表输入**真的**变了时
  /// 递增(新事件落库 / 覆盖水位前移 / 淘汰 / 最早锚点到手)。
  ///
  /// 保持**同步**是刻意的:它在 Go 侧只读几个原子变量、不碰 SQLite,而调用方要在每一拍
  /// 里同步决定「这拍要不要查」。耗时的是查询,不是判断,只把查询搬走就够了。
  /// 将来若它变成要查库,就必须一并挪到后台。
  ///
  /// 哨兵:`''` = 取不到(旧版核心无此导出 / 引擎未起),调用方必须退回「照常查询」,
  /// **绝不能当成「没变化」**,否则一次瞬时失败会让图表永久停止刷新。
  /// `'{}'` = 真的一个实例都没有。
  String chartVersionsJson();

  /// 触发按需回填:确保某实例本地覆盖延伸到 now-hours(异步、即时返回)。
  /// UI 在拉大跨度时调用,补齐进度由后续 chartSeriesJson 的 coverageFrom 体现。
  void ensureCoverage(String instance, int hours);

  /// 告知引擎弹层是否打开(打开则提频)。
  void setForeground(bool open);

  // ---- 调试:客户端读流量采样 ----

  /// 开/关采样。enabled=true 重置缓冲并按上限开采;false 停采(保留已采样本)。
  void debugSet(
      {required bool enabled,
      required int maxSamples,
      required int maxMemBytes});

  /// 读取采样报告 JSON(无论开关状态均有效)。
  String debugReportJson();

  /// 清空已采样本(保留开关与上限)。
  void debugReset();

  /// 释放实现方持有的后台资源(如查询用的 isolate)。进程退出前调用。
  void shutdown();
}
