import 'package:flutter/material.dart';

import '../state/settings_store.dart';

/// SettingsPage 让用户填 base_url + api_key。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.initial,
    required this.onSave,
    this.onCancel,
  });

  final Settings initial;
  final void Function(Settings) onSave;
  final VoidCallback? onCancel;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrl =
      TextEditingController(text: widget.initial.baseUrl);
  late final TextEditingController _apiKey =
      TextEditingController(text: widget.initial.apiKey);
  bool _obscure = true;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _save() {
    final s = Settings(baseUrl: _baseUrl.text, apiKey: _apiKey.text);
    widget.onSave(s);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('sub2api 连接', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          const Text('Base URL', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _baseUrl,
            decoration: _dec('https://your-sub2api-host'),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          const Text('Admin API Key (x-api-key)', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          TextField(
            controller: _apiKey,
            obscureText: _obscure,
            decoration: _dec('sk-...').copyWith(
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 16),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onCancel != null)
                TextButton(onPressed: widget.onCancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _save, child: const Text('保存并连接')),
            ],
          ),
        ],
      ),
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: const OutlineInputBorder(),
      );
}
