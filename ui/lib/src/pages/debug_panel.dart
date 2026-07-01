import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';

/// DebugPanel 是「客户端读流量采样」的独立调试视图(壳把窗口放大后铺满它)。
///
/// 数据流全部走回调,不直接触碰 FFI/source,保持 UI 分层:
///   - [enabled]/[maxSamples]/[maxMemMB] 当前配置(壳持久化的值)
///   - [onChanged] 应用「开关 + 两个上限」(壳持久化并调 FFI 的 debugSet)
///   - [fetchReport] 读一次报告 JSON(壳转发 source.debugReportJson)
///   - [onReset] 清空已采样本(壳转发 source.debugReset)
///   - [onClose] 关闭面板(壳恢复弹层尺寸)
class DebugPanel extends StatefulWidget {
  const DebugPanel({
    super.key,
    required this.enabled,
    required this.maxSamples,
    required this.maxMemMB,
    required this.onChanged,
    required this.fetchReport,
    required this.onReset,
    required this.onClose,
  });

  final bool enabled;
  final int maxSamples;
  final int maxMemMB;
  final void Function(bool enabled, int maxSamples, int maxMemMB) onChanged;
  final String Function() fetchReport;
  final VoidCallback onReset;
  final VoidCallback onClose;

  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<DebugPanel> {
  late final TextEditingController _samplesCtl =
      TextEditingController(text: '${widget.maxSamples}');
  late final TextEditingController _memCtl =
      TextEditingController(text: '${widget.maxMemMB}');
  Map<String, dynamic> _report = const {};
  String _raw = '{}';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 开着就每 2s 自动刷新一次,给「实时感」;关掉面板即停。
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _samplesCtl.dispose();
    _memCtl.dispose();
    super.dispose();
  }

  void _refresh() {
    final raw = widget.fetchReport();
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      parsed = const {};
    }
    if (mounted) {
      setState(() {
        _raw = raw;
        _report = parsed;
      });
    }
  }

  int _parseInt(TextEditingController c, int fallback) {
    final v = int.tryParse(c.text.trim());
    return (v == null || v <= 0) ? fallback : v;
  }

  // 应用当前开关 + 两个上限(改上限会以新配置重开采样、重置缓冲)。
  void _apply(bool enabled) {
    final samples = _parseInt(_samplesCtl, widget.maxSamples);
    final mem = _parseInt(_memCtl, widget.maxMemMB);
    widget.onChanged(enabled, samples, mem);
    // 稍后拉一版新报告(FFI 已切状态)。
    Future.delayed(const Duration(milliseconds: 120), _refresh);
  }

  Future<void> _copyJson() async {
    // 复制美化后的 JSON,便于粘出来看。
    String pretty = _raw;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(_report);
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: pretty));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制报告 JSON')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = (_report['enabled'] as bool?) ?? widget.enabled;
    final samples = (_report['samples'] as num?)?.toInt() ?? 0;
    final truncated = (_report['truncated'] as bool?) ?? false;
    final droppedOver = (_report['droppedOver'] as num?)?.toInt() ?? 0;
    final memBytes = (_report['memBytes'] as num?)?.toInt() ?? 0;
    final instances = (_report['instances'] as List?) ?? const [];

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titleBar(theme),
              const SizedBox(height: 8),
              _controls(theme, enabled),
              const SizedBox(height: 8),
              _summary(theme, enabled, samples, truncated, droppedOver, memBytes),
              const Divider(height: 16),
              Expanded(
                child: instances.isEmpty
                    ? Center(
                        child: Text(
                          enabled ? '暂无采样(等待请求发生…)' : '采样未开启',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: instances.length,
                        itemBuilder: (_, i) =>
                            _instanceCard(theme, instances[i] as Map<String, dynamic>),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleBar(ThemeData theme) {
    return Row(
      children: [
        const Icon(Icons.insights_outlined, size: 18),
        const SizedBox(width: 8),
        Text('网络采样(调试)',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(),
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: _refresh,
        ),
        IconButton(
          tooltip: '复制 JSON',
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          onPressed: _copyJson,
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close, size: 18),
          onPressed: widget.onClose,
        ),
      ],
    );
  }

  Widget _controls(ThemeData theme, bool enabled) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: enabled,
              onChanged: (v) => _apply(v),
            ),
            Text(enabled ? '采样中' : '已停止', style: theme.textTheme.bodyMedium),
          ],
        ),
        _numField(theme, '最大采样次数', _samplesCtl, width: 130),
        _numField(theme, '内存上限(MB)', _memCtl, width: 120),
        FilledButton.tonal(
          onPressed: () => _apply(enabled),
          child: const Text('应用上限'),
        ),
        OutlinedButton.icon(
          onPressed: () {
            widget.onReset();
            Future.delayed(const Duration(milliseconds: 120), _refresh);
          },
          icon: const Icon(Icons.delete_sweep_outlined, size: 16),
          label: const Text('清空'),
        ),
      ],
    );
  }

  Widget _numField(ThemeData theme, String label, TextEditingController c,
      {required double width}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        ),
      ),
    );
  }

  Widget _summary(ThemeData theme, bool enabled, int samples, bool truncated,
      int droppedOver, int memBytes) {
    final cs = theme.colorScheme;
    final chips = <Widget>[
      _chip(theme, '样本 $samples', cs.primaryContainer, cs.onPrimaryContainer),
      _chip(theme, '内存 ${fmtBytes(memBytes)}', cs.secondaryContainer,
          cs.onSecondaryContainer),
    ];
    if (truncated) {
      chips.add(_chip(theme, '已达上限,停采(丢弃 $droppedOver)',
          cs.errorContainer, cs.onErrorContainer));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(spacing: 8, runSpacing: 6, children: chips),
    );
  }

  Widget _chip(ThemeData theme, String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: fg)),
      );

  Widget _instanceCard(ThemeData theme, Map<String, dynamic> inst) {
    final name = (inst['instance'] as String?) ?? '(未命名)';
    final requests = (inst['requests'] as num?)?.toInt() ?? 0;
    final wireTotal = (inst['wireTotal'] as num?)?.toInt() ?? 0;
    final payloadTotal = (inst['payloadTotal'] as num?)?.toInt() ?? 0;
    final apis = (inst['apis'] as List?) ?? const [];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Text('$requests 次 · 网络 ${fmtBytes(wireTotal)} · 数据 ${fmtBytes(payloadTotal)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 4),
            for (final api in apis)
              _apiTile(theme, api as Map<String, dynamic>),
          ],
        ),
      ),
    );
  }

  Widget _apiTile(ThemeData theme, Map<String, dynamic> api) {
    final endpoint = (api['endpoint'] as String?) ?? '';
    final requests = (api['requests'] as num?)?.toInt() ?? 0;
    final wireTotal = (api['wireTotal'] as num?)?.toInt() ?? 0;
    final payloadTotal = (api['payloadTotal'] as num?)?.toInt() ?? 0;
    final wireAvg = (api['wireAvg'] as num?)?.toDouble() ?? 0;
    final payloadAvg = (api['payloadAvg'] as num?)?.toDouble() ?? 0;
    final byPageSize = (api['byPageSize'] as List?) ?? const [];

    return Theme(
      // 去掉 ExpansionTile 展开分隔线,更紧凑。
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.only(left: 12, right: 4, bottom: 6),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        title: Text(endpoint,
            style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
        subtitle: Text(
          '$requests 次 · 平均 网络 ${fmtBytes(wireAvg)} / 数据 ${fmtBytes(payloadAvg)}'
          ' · 合计 ${fmtBytes(wireTotal)} / ${fmtBytes(payloadTotal)}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        children: [
          _psHeader(theme),
          for (final ps in byPageSize) _psRow(theme, ps as Map<String, dynamic>),
        ],
      ),
    );
  }

  Widget _psHeader(ThemeData theme) {
    final st = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('page_size', style: st)),
          Expanded(flex: 2, child: Text('次数', style: st, textAlign: TextAlign.right)),
          Expanded(flex: 4, child: Text('网络均值', style: st, textAlign: TextAlign.right)),
          Expanded(flex: 4, child: Text('数据均值', style: st, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _psRow(ThemeData theme, Map<String, dynamic> ps) {
    final pageSize = (ps['pageSize'] as num?)?.toInt() ?? 0;
    final requests = (ps['requests'] as num?)?.toInt() ?? 0;
    final wireAvg = (ps['wireAvg'] as num?)?.toDouble() ?? 0;
    final payloadAvg = (ps['payloadAvg'] as num?)?.toDouble() ?? 0;
    final st = const TextStyle(fontSize: 12);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
              flex: 3,
              child: Text(pageSize == 0 ? '—' : '$pageSize', style: st)),
          Expanded(
              flex: 2,
              child: Text('$requests', style: st, textAlign: TextAlign.right)),
          Expanded(
              flex: 4,
              child: Text(fmtBytes(wireAvg), style: st, textAlign: TextAlign.right)),
          Expanded(
              flex: 4,
              child: Text(fmtBytes(payloadAvg), style: st, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}
