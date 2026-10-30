import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ml_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_settings.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/kumaflow_brain/kumaflow_brain_client.dart';
import '../services/subsonic_service.dart';
import 'kumaflow_brain_screen.dart';

/// KumaFlow Brain: тумблер (по умолчанию ВЫКЛ = чисто локально) + URL.
/// user_id = uuid из POST /api/users/by-credentials (создать 1 раз, сохранить).
/// Только доверенная LAN — наружу без токена не выставлять.
///
/// Живёт во вкладке «Интеграции»; в ML-табе только ссылка сюда.
class KumaFlowBrainSection extends StatefulWidget {
  final bool isDark;
  const KumaFlowBrainSection({super.key, required this.isDark});

  @override
  State<KumaFlowBrainSection> createState() => _KumaFlowBrainSectionState();
}

class _BrainSectionCard extends StatelessWidget {
  final Widget child;
  final bool isDark;

  const _BrainSectionCard({required this.child, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

class _BrainStatRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _BrainStatRow({
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _KumaFlowBrainSectionState extends State<KumaFlowBrainSection> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final s = Provider.of<KumaFlowBrainSettings>(context, listen: false);
    _urlCtrl = TextEditingController(text: s.baseUrl);
    _tokenCtrl = TextEditingController(text: s.apiToken);
    _userCtrl = TextEditingController(text: s.username);
    _passCtrl = TextEditingController();
    // Логин уже введён при подключении плеера к серверу — подставляем его,
    // чтобы не вбивать второй раз. Пароль не светим в UI, но используем
    // серверный при Подключении, если поле пустое.
    if (_userCtrl.text.trim().isEmpty) {
      try {
        final sub = Provider.of<SubsonicService>(context, listen: false);
        final u = sub.config?.username.trim() ?? '';
        if (u.isNotEmpty) _userCtrl.text = u;
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<KumaFlowBrainSettings>(context);
    final bridge = Provider.of<KumaFlowBrainBridge>(context);
    final isDark = widget.isDark;

    return _BrainSectionCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology_rounded, color: Color(0xFFAF52DE), size: 24),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('KumaFlow Brain',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Switch(
                value: settings.enabled,
                onChanged: _busy
                    ? null
                    : (v) async {
                        await settings.setEnabled(v);
                        if (mounted) {
                          setState(() => _status =
                              v ? 'Включено. Проверьте URL и подключение.' : 'Выключено — чисто локально.');
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'ВЫКЛ = мобила работает как раньше, полностью локально. ВКЛ + URL = общение с KumaFlow Brain (best-effort, очередь не рвётся). Только LAN!',
            style: TextStyle(
                fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'URL KumaFlow Brain',
              hintText: 'http://192.168.1.10:3030',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (v) => settings.setBaseUrl(v),
          ),
          if (settings.isDockerHostname)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '⚠ Хост backend/bridge виден только внутри docker-сети. С телефона впиши LAN-IP сервера, напр. http://192.168.1.10:3030',
                style: TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenCtrl,
            decoration: const InputDecoration(
              labelText: 'Токен KumaFlow Brain (BRAIN_API_TOKEN, если задан на сервере)',
              hintText: 'пусто = без auth, доверенная LAN',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            obscureText: true,
            onSubmitted: (v) => settings.setApiToken(v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          await settings.setBaseUrl(_urlCtrl.text);
                          await settings.setApiToken(_tokenCtrl.text);
                          setState(() {
                            _busy = true;
                            _status = 'Проверка…';
                          });
                          try {
                            final c = KumaFlowBrainClient(settings.normalizedBaseUrl,
                                authToken: settings.apiToken);
                            final ok = await c.ping();
                            if (mounted) {
                              setState(() => _status =
                                  ok ? 'Сервер отвечает (docs OK).' : 'Сервер недоступен — локальный fallback.');
                            }
                          } catch (e) {
                            if (mounted) setState(() => _status = 'Ошибка: $e');
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  icon: const Icon(Icons.wifi_find_rounded, size: 16),
                  label: const Text('Проверить'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_busy || !settings.enabled)
                      ? null
                      : () async {
                          await settings.setBaseUrl(_urlCtrl.text);
                          setState(() {
                            _busy = true;
                            _status = 'Синхронизация…';
                          });
                          try {
                            final ml = Provider.of<MLService>(context, listen: false);
                            final res = await bridge.syncFromMobileFull(ml);
                            if (mounted) {
                              setState(() => _status =
                                  'Синк OK: ${res['fav_added'] ?? '?'} fav / ${res['dis_added'] ?? '?'} dis.');
                            }
                          } catch (e) {
                            if (mounted) setState(() => _status = 'Синк: $e');
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  icon: const Icon(Icons.sync_rounded, size: 16),
                  label: Text(bridge.isSyncing ? 'Синк…' : 'Синхронить'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _userCtrl,
            decoration: const InputDecoration(
              labelText: 'Логин (Navidrome — подставлен с сервера)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passCtrl,
            decoration: const InputDecoration(
              labelText: 'Пароль (пусто = взять с сервера, только LAN)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            obscureText: true,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          await settings.setBaseUrl(_urlCtrl.text);
                          await settings.setApiToken(_tokenCtrl.text);
                          final u = _userCtrl.text.trim();
                          var p = _passCtrl.text;
                          // Пароль уже есть в конфиге сервера — не заставляем
                          // вбивать второй раз, если логин совпадает.
                          if (p.isEmpty) {
                            try {
                              final sub = Provider.of<SubsonicService>(
                                  context,
                                  listen: false);
                              if ((sub.config?.username.trim() ?? '') == u) {
                                p = sub.config?.password ?? '';
                              }
                            } catch (_) {}
                          }
                          if (u.isEmpty || p.isEmpty) {
                            setState(() => _status =
                                'Введите логин и пароль (или подключите сервер в Настройки → Сервер).');
                            return;
                          }
                          setState(() {
                            _busy = true;
                            _status = 'Подключение…';
                          });
                          try {
                            final c = KumaFlowBrainClient(settings.normalizedBaseUrl,
                                authToken: settings.apiToken);
                            final res = await c.byCredentials(u, p);
                            final user = res['user'];
                            final id = (user is Map
                                    ? (user['id'] ?? user['user_id'])
                                    : res['user_id'])
                                ?.toString();
                            if (id == null || id.isEmpty) {
                              throw KumaFlowBrainException('Нет user id в ответе: $res');
                            }
                            await settings.setUser(id, u);
                            _passCtrl.clear();
                            if (mounted) {
                              setState(() => _status = 'Подключено: $u ($id)');
                            }
                          } catch (e) {
                            if (mounted) setState(() => _status = 'Ошибка: $e');
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: const Text('Подключить'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Отвязать user_id',
                onPressed: _busy
                    ? null
                    : () async {
                        await settings.clearUser();
                        if (mounted) setState(() => _status = 'user_id очищен.');
                      },
                icon: const Icon(Icons.link_off_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _BrainStatRow(
              label: 'Статус',
              value: !settings.enabled
                  ? 'выкл (локально)'
                  : bridge.isActive
                      ? 'вкл + связан'
                      : 'вкл, нет URL/user',
              isDark: isDark),
          if (settings.userId.isNotEmpty)
            SelectableText('user_id: ${settings.userId}',
                style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black38)),
          const Divider(height: 24),
          // Волна как источник: отдельный тумблер + N.
          Row(
            children: [
              const Icon(Icons.waves_rounded,
                  color: Color(0xFF007AFF), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('Волна из KumaFlow Brain',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Switch(
                value: settings.waveEnabled,
                onChanged: !bridge.isActive
                    ? null
                    : (v) => settings.setWaveEnabled(v),
              ),
            ],
          ),
          Text(
            bridge.isActive
                ? 'Волна: экран KumaFlow Brain + режим KF-Brain в AutoDJ.'
                : 'Сначала ВКЛ + URL + Подключить выше.',
            style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black54),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: settings.waveCount.toDouble(),
                  min: 5,
                  max: 30,
                  divisions: 5,
                  label: '${settings.waveCount}',
                  onChanged: (v) =>
                      settings.setWaveCount(v.round()),
                ),
              ),
              Text('${settings.waveCount}'),
            ],
          ),
          // Фильтры волны живут в одном месте — «Моя волна → Настроить»
          // на главной. Дубли здесь убраны, чтобы не было двух источников.
          Text(
            'Фильтры волны — в «Моя волна → Настроить» на главной.',
            style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black54),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: !bridge.isActive
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const KumaFlowBrainScreen()),
                      ),
              icon: const Icon(Icons.psychology_rounded, size: 16),
                label: const Text('Открыть экраны KumaFlow Brain'),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(_status!,
                style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white70 : Colors.black87)),
          ],
        ],
      ),
    );
  }
}
