import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart' as xml;
import '../models/podcast.dart';

class PodcastService {
  static final PodcastService _instance = PodcastService._internal();
  factory PodcastService() => _instance;
  PodcastService._internal();

  static const _keySubscriptions = 'podcast_subscriptions';
  static const _keyEpisodesPrefix = 'podcast_episodes_';

  /// Открытые источники по умолчанию — видны сразу без добавления
  static const List<Map<String, String>> defaultFeeds = [
    {
      'title': 'Чай с психологом',
      'feedUrl': 'https://cloud.mave.digital/73683',
      'author': 'Egor Egorov',
      'image': 'https://podster.fm/image-storage/394061/conversions/rlnqrKMy566DlYSO-xl.jpg',
    },
    {
      'title': 'У Холмов Есть Подкаст',
      'feedUrl': 'https://cloud.mave.digital/33489',
      'author': 'У Холмов Есть Подкаст',
      'image': 'https://is1-ssl.mzstatic.com/image/thumb/Podcasts113/v4/bf/b1/2c/bfb12cd4-f2ac-ace8-3b16-34e5d6033f64/mza_346599430136030555.jpg/600x600bb.jpg',
    },
    {
      'title': 'TED Talks Daily',
      'feedUrl': 'https://feeds.feedburner.com/tedtalks_video',
      'author': 'TED',
      'image': 'https://images.unsplash.com/photo-1522202176988-66273c2fd55f?w=400',
    },
    {
      'title': 'Lex Fridman Podcast',
      'feedUrl': 'https://lexfridman.com/feed/podcast/',
      'author': 'Lex Fridman',
      'image': 'https://images.unsplash.com/photo-1590602847861-f357a8f69e06?w=400',
    },
    {
      'title': 'Radiolab',
      'feedUrl': 'https://feeds.wnyc.org/radiolab',
      'author': 'WNYC Studios',
      'image': 'https://images.unsplash.com/photo-1484704849700-f032a568e944?w=400',
    },
  ];

  // ---------- Persistence ----------
  Future<List<Podcast>> getSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySubscriptions);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Podcast.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveSubscriptions(List<Podcast> pods) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySubscriptions, jsonEncode(pods.map((e) => e.toJson()).toList()));
  }

  Future<void> addSubscription(Podcast podcast) async {
    final list = await getSubscriptions();
    if (list.any((p) => p.feedUrl == podcast.feedUrl)) return;
    list.add(podcast);
    await _saveSubscriptions(list);
  }

  Future<void> removeSubscription(String podcastId, {String? feedUrl}) async {
    final list = await getSubscriptions();
    final removed = list.where((p) => p.id == podcastId || (feedUrl != null && p.feedUrl == feedUrl)).toList();
    list.removeWhere((p) => p.id == podcastId || (feedUrl != null && p.feedUrl == feedUrl));
    // Fallback: if nothing removed by id/feedUrl, try by feedUrl from any match
    if (list.length == (await getSubscriptions()).length && feedUrl != null) {
      // already handled
    }
    await _saveSubscriptions(list);
    final prefs = await SharedPreferences.getInstance();
    // clear caches for all possible keys
    await prefs.remove('$_keyEpisodesPrefix$podcastId');
    if (feedUrl != null) {
      // Remove any cache keyed by any id that had same feedUrl
      for (final r in removed) {
        await prefs.remove('$_keyEpisodesPrefix${r.id}');
      }
    }
  }

  Future<void> updateSubscription(Podcast podcast) async {
    final list = await getSubscriptions();
    final idx = list.indexWhere((p) => p.id == podcast.id);
    if (idx != -1) {
      list[idx] = podcast;
      await _saveSubscriptions(list);
    }
  }

  // ---------- RSS Parsing ----------
  String _generateId(String feedUrl) {
    final hash = feedUrl.split('').fold(0, (a, b) => ((a << 5) - a) + b.codeUnitAt(0));
    return 'podcast-${hash.abs().toString()}-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
  }

  Future<String> _fetchString(String url) async {
    final uri = Uri.parse(url.trim());
    // 30s timeout + retry, with HttpClient connectionTimeout = 30s to avoid 15s socket cut
    Future<http.Response> doFetch() async {
      final httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      httpClient.badCertificateCallback = (cert, host, port) => true;
      final ioClient = IOClient(httpClient);
      try {
        return await ioClient.get(uri, headers: {
          'User-Agent': 'KumaFlow/1.0 (Podcast)',
          'Accept': 'text/html,application/xhtml+xml,application/xml,application/rss+xml,*/*;q=0.8',
          'Accept-Language': 'ru,en;q=0.8',
        }).timeout(const Duration(seconds: 30));
      } finally {
        ioClient.close();
      }
    }

    http.Response resp;
    try {
      resp = await doFetch();
    } on TimeoutException catch (e) {
      throw TimeoutException('Превышено время ожидания (30с) для $url: $e');
    } on SocketException catch (e) {
      // retry once after 1s for transient feedburner hiccups
      await Future.delayed(const Duration(seconds: 1));
      try {
        resp = await doFetch();
      } catch (e2) {
        // keep original socket error with host info for UI
        throw Exception('SocketException: $e2 (host: ${uri.host})');
      }
    }
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    return resp.body;
  }

  // ignore: unused_element
  Future<String> _fetchRss(String url) => _fetchString(url);

  String? _extractRssUrlFromHtml(String html, String baseUrl) {
    // 1. podster: data-page JSON contains rss_url
    try {
      final dataPageMatch = RegExp(r'data-page="([^"]+)"').firstMatch(html);
      if (dataPageMatch != null) {
        String jsonStr = dataPageMatch.group(1)!;
        jsonStr = jsonStr.replaceAll('&quot;', '"').replaceAll('&amp;', '&').replaceAll('&#039;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>');
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final props = data['props'] as Map<String, dynamic>?;
        if (props != null) {
          final podcast = props['podcast'] as Map<String, dynamic>?;
          if (podcast != null && podcast['rss_url'] != null) {
            return podcast['rss_url'].toString();
          }
          final txt = jsonEncode(props);
          final m = RegExp(r'"rss_url"\s*:\s*"([^"]+)"').firstMatch(txt);
          if (m != null) return m.group(1)!.replaceAll(r'\/', '/');
        }
      }
    } catch (_) {}
    // 2. castbox: window.__INITIAL_STATE__ = "URI_ENCODED_JSON"
    try {
      final m = RegExp(r'window\.__INITIAL_STATE__\s*=\s*"([^"]+)"').firstMatch(html);
      if (m != null) {
        final enc = m.group(1)!;
        final dec = Uri.decodeComponent(enc);
        final j = jsonDecode(dec) as Map<String, dynamic>;
        final chInfo = (j['ch'] as Map?)?['chInfo'] as Map?;
        if (chInfo != null && chInfo['rss_url'] != null) {
          return chInfo['rss_url'].toString();
        }
        final m2 = RegExp(r'"rss_url"\s*:\s*"([^"]+)"').firstMatch(dec);
        if (m2 != null) return m2.group(1)!.replaceAll(r'\/', '/');
      }
    } catch (_) {}
    // 3. generic <link rel="alternate" type="application/rss+xml" href="...">
    try {
      final linkTags = RegExp(r'<link[^>]*>', caseSensitive: false).allMatches(html);
      for (final tag in linkTags) {
        final txt = tag.group(0)!.toLowerCase();
        if (txt.contains('application/rss+xml') || txt.contains('application/atom+xml')) {
          final hrefMatch = RegExp(r'href="([^"]+)"').firstMatch(tag.group(0)!);
          final hrefMatch2 = RegExp("href='([^']+)'").firstMatch(tag.group(0)!);
          final href = hrefMatch?.group(1) ?? hrefMatch2?.group(1);
          if (href != null && href.isNotEmpty) {
            String resolved = href;
            if (!resolved.startsWith('http')) resolved = Uri.parse(baseUrl).resolve(resolved).toString();
            return resolved;
          }
        }
      }
    } catch (_) {}
    // 4. generic fallback: any "rss":"https://..." in HTML (podcast.ru / pc.st)
    try {
      final m = RegExp(r'"rss"\s*:\s*"([^"]+)"').firstMatch(html);
      if (m != null) {
        final rss = m.group(1)!.replaceAll(r'\/', '/');
        if (rss.startsWith('http')) return rss;
      }
    } catch (_) {}
    return null;
  }

  // ignore: unused_element
  Podcast _parsePodcastFromHtml(String html, String url) {
    String title = 'Unknown Podcast';
    String author = 'Unknown Author';
    String description = '';
    String imageUrl = '';
    try {
      final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
      if (titleMatch != null) title = _stripHtml(titleMatch.group(1)!.trim()).split('|').first.trim();
      final ogTitle = RegExp(r'property="og:title"[^>]*content="([^"]+)"', caseSensitive: false).firstMatch(html);
      if (ogTitle != null && ogTitle.group(1)!.trim().isNotEmpty) title = _stripHtml(ogTitle.group(1)!.trim());
      final authorMatch = RegExp(r'name="author"[^>]*content="([^"]+)"', caseSensitive: false).firstMatch(html);
      if (authorMatch != null) author = _stripHtml(authorMatch.group(1)!.trim());
      final ogImage = RegExp(r'property="og:image"[^>]*content="([^"]+)"', caseSensitive: false).firstMatch(html);
      if (ogImage != null) imageUrl = ogImage.group(1)!.trim();
      final descMatch = RegExp(r'name="description"[^>]*content="([^"]+)"', caseSensitive: false).firstMatch(html);
      if (descMatch != null) description = _stripHtml(descMatch.group(1)!.trim());
    } catch (_) {}
    return Podcast(
      id: _generateId(url),
      title: title.isEmpty ? 'Unknown Podcast' : title,
      description: description,
      author: author,
      imageUrl: imageUrl.isEmpty ? null : imageUrl,
      feedUrl: url,
      episodeCount: 0,
    );
  }

  Podcast _parsePodcastFromXml(String xmlString, String feedUrl) {
    final doc = xml.XmlDocument.parse(xmlString);
    final channel = doc.findAllElements('channel').firstOrNull;
    if (channel == null) throw Exception('Invalid RSS: no channel');

    String getText(String tag) {
      final el = channel.findElements(tag).firstOrNull;
      if (el != null) return el.innerText.trim();
      // try with namespace
      for (final e in channel.children.whereType<xml.XmlElement>()) {
        if (e.name.local == tag) return e.innerText.trim();
      }
      return '';
    }

    String getNsText(String ns, String tag) {
      for (final e in channel.children.whereType<xml.XmlElement>()) {
        if (e.name.local == tag && e.name.prefix == ns) return e.innerText.trim();
      }
      // fallback findElements with qualified name
      try {
        final el = channel.findElements('$ns:$tag').firstOrNull;
        if (el != null) return el.innerText.trim();
      } catch (_) {}
      return '';
    }

    final title = getText('title').isNotEmpty ? getText('title') : 'Unknown Podcast';
    String author = getText('author');
    if (author.isEmpty) author = getNsText('itunes', 'author');
    if (author.isEmpty) {
      // dc:creator
      for (final e in channel.children.whereType<xml.XmlElement>()) {
        if (e.name.local == 'creator') { author = e.innerText.trim(); break; }
      }
    }
    if (author.isEmpty) author = 'Unknown Author';

    String description = getText('description');
    if (description.isEmpty) description = getNsText('itunes', 'summary');
    String imageUrl = '';
    // itunes:image href
    for (final e in channel.children.whereType<xml.XmlElement>()) {
      if (e.name.local == 'image' && e.name.prefix == 'itunes') {
        imageUrl = e.getAttribute('href') ?? '';
        break;
      }
      if (e.name.local == 'image' && e.name.prefix == 'podcast') {
        if (imageUrl.isEmpty) imageUrl = e.getAttribute('href') ?? '';
      }
    }
    if (imageUrl.isEmpty) {
      final imgEl = channel.findElements('image').firstOrNull;
      if (imgEl != null) {
        final urlEl = imgEl.findElements('url').firstOrNull;
        if (urlEl != null) imageUrl = urlEl.innerText.trim();
      }
    }
    String link = getText('link');

    return Podcast(
      id: _generateId(feedUrl),
      title: _stripHtml(title),
      description: _stripHtml(description),
      author: _stripHtml(author),
      link: link.isEmpty ? null : link,
      imageUrl: imageUrl.isEmpty ? null : imageUrl,
      feedUrl: feedUrl,
      episodeCount: 0,
    );
  }

  List<PodcastEpisode> _parseEpisodesFromXml(String xmlString, String podcastId) {
    final doc = xml.XmlDocument.parse(xmlString);
    final channel = doc.findAllElements('channel').firstOrNull;
    if (channel == null) return [];
    final items = channel.findElements('item').toList();
    final episodes = <PodcastEpisode>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      String getT(String tag) {
        final el = item.findElements(tag).firstOrNull;
        if (el != null) return el.innerText.trim();
        for (final e in item.children.whereType<xml.XmlElement>()) {
          if (e.name.local == tag) return e.innerText.trim();
        }
        return '';
      }

      String getNs(String ns, String tag) {
        for (final e in item.children.whereType<xml.XmlElement>()) {
          if (e.name.local == tag && e.name.prefix == ns) return e.innerText.trim();
        }
        try {
          final el = item.findElements('$ns:$tag').firstOrNull;
          if (el != null) return el.innerText.trim();
        } catch (_) {}
        return '';
      }

      final title = getT('title').isNotEmpty ? getT('title') : 'Episode ${i + 1}';
      String desc = getT('description');
      if (desc.isEmpty) desc = getNs('itunes', 'summary');
      final pubDateStr = getT('pubDate');
      DateTime? pubDate;
      if (pubDateStr.isNotEmpty) {
        // try RFC822
        try {
          pubDate = HttpDate.parse(pubDateStr);
        } catch (_) {
          pubDate = DateTime.tryParse(pubDateStr);
        }
      }
      String durationStr = getNs('itunes', 'duration');
      int duration = 0;
      if (durationStr.isNotEmpty) duration = _parseDuration(durationStr);

      String audioUrl = '';
      for (final e in item.children.whereType<xml.XmlElement>()) {
        if (e.name.local == 'enclosure') {
          audioUrl = e.getAttribute('url') ?? '';
          break;
        }
      }
      // fallback: find enclosure via findElements
      if (audioUrl.isEmpty) {
        final enc = item.findElements('enclosure').firstOrNull;
        if (enc != null) audioUrl = enc.getAttribute('url') ?? '';
      }
      // also try media:content
      if (audioUrl.isEmpty) {
        for (final e in item.children.whereType<xml.XmlElement>()) {
          if (e.name.local == 'content' && e.getAttribute('url') != null) {
            audioUrl = e.getAttribute('url')!;
            break;
          }
        }
      }
      if (audioUrl.isEmpty) continue; // skip without audio

      String? img;
      for (final e in item.children.whereType<xml.XmlElement>()) {
        if (e.name.local == 'image' && e.name.prefix == 'itunes') {
          img = e.getAttribute('href');
          break;
        }
      }

      final guid = getT('guid');

      episodes.add(PodcastEpisode(
        id: 'ep-$podcastId-$i-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}',
        podcastId: podcastId,
        title: _stripHtml(title),
        description: _stripHtml(desc),
        audioUrl: audioUrl,
        imageUrl: img,
        duration: duration,
        publishedAt: pubDate,
        guid: guid.isEmpty ? null : guid,
      ));
    }
    return episodes;
  }

  int _parseDuration(String s) {
    s = s.trim();
    if (s.isEmpty) return 0;
    if (s.contains(':')) {
      final parts = s.split(':').map((e) => int.tryParse(e) ?? 0).toList();
      if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
      if (parts.length == 2) return parts[0] * 60 + parts[1];
      if (parts.length == 1) return parts[0];
    }
    return int.tryParse(s) ?? 0;
  }

  String _stripHtml(String s) {
    if (!s.contains('<')) return s;
    // simple tag strip
    return s.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  bool _looksLikeHtml(String s) {
    final t = s.trimLeft().toLowerCase();
    return t.startsWith('<!doctype html') || t.startsWith('<html') || t.contains('<head') && t.contains('<body') || t.startsWith('<!doctype');
  }

  bool _looksLikeRss(String s) {
    final t = s.trimLeft().toLowerCase();
    return t.contains('<rss') || t.contains('<channel') || t.contains('<feed');
  }

  /// Universal resolver: accepts RSS URL or HTML page URL (castbox/podster/mave)
  Future<({Podcast podcast, List<PodcastEpisode> episodes})> fetchPodcast(String inputUrl) async {
    final input = inputUrl.trim();
    if (input.isEmpty) throw Exception('Пустая ссылка');
    final content = await _fetchString(input);
    final trimmed = content.trimLeft();
    // If already RSS/XML — parse directly
    if (_looksLikeRss(content) && !_looksLikeHtml(content)) {
      final podcast = _parsePodcastFromXml(content, input);
      final episodes = _parseEpisodesFromXml(content, podcast.id);
      return (podcast: podcast.copyWith(episodeCount: episodes.length), episodes: episodes);
    }
    // If HTML — try to discover RSS url inside
    if (_looksLikeHtml(content) || trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html')) {
      final discovered = _extractRssUrlFromHtml(content, input);
      if (discovered != null && discovered.isNotEmpty) {
        try {
          final rssContent = await _fetchString(discovered);
          if (_looksLikeRss(rssContent)) {
            final podcast = _parsePodcastFromXml(rssContent, discovered);
            final episodes = _parseEpisodesFromXml(rssContent, podcast.id);
            return (podcast: podcast.copyWith(episodeCount: episodes.length), episodes: episodes);
          }
        } catch (e) {
          throw Exception('На странице найден RSS $discovered, но не удалось загрузить: $e');
        }
      }
      // Fallback: try to parse HTML meta as stub (so user sees title/cover)
      // But we still want episodes — throw helpful message with hint
      throw Exception('Страница не содержит прямой RSS. Если это podster.fm — RSS: https://podster.fm/rss.xml?pid=ID . Если castbox — откройте https://cloud.mave.digital/<ID> . Поддерживаем также прямую ссылку RSS.');
    }
    // Unknown content — try XML parse anyway
    if (_looksLikeRss(content)) {
      final podcast = _parsePodcastFromXml(content, input);
      final episodes = _parseEpisodesFromXml(content, podcast.id);
      return (podcast: podcast.copyWith(episodeCount: episodes.length), episodes: episodes);
    }
    throw Exception('Не удалось определить формат по ссылке. Вставьте прямую RSS-ссылку (заканчивается на .xml или /rss).');
  }

  // Deprecated alias kept for provider compatibility
  Future<({Podcast podcast, List<PodcastEpisode> episodes})> fetchPodcastFromRss(String feedUrl) => fetchPodcast(feedUrl);

  Future<void> cacheEpisodes(String podcastId, List<PodcastEpisode> eps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_keyEpisodesPrefix$podcastId', jsonEncode(eps.map((e) => e.toJson()).toList()));
  }

  Future<List<PodcastEpisode>> getCachedEpisodes(String podcastId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_keyEpisodesPrefix$podcastId');
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => PodcastEpisode.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- iTunes + Podster + podcast.ru(pc.st) Search ----------
  Future<List<PodcastSearchResult>> searchPodcasts(String query) async {
    if (query.trim().isEmpty) return [];
    final results = <PodcastSearchResult>[];
    final itunesF = _searchItunes(query);
    final podsterF = _searchPodster(query);
    final pcStF = _searchPcSt(query);
    final lists = await Future.wait([itunesF, podsterF, pcStF]);
    results.addAll(lists[0]);
    final seen = results.map((r) => r.feedUrl).toSet();
    for (final r in lists[1]) {
      if (!seen.contains(r.feedUrl)) {
        results.add(r);
        seen.add(r.feedUrl);
      }
    }
    for (final r in lists[2]) {
      if (!seen.contains(r.feedUrl)) results.add(r);
    }
    return results;
  }

  Future<List<PodcastSearchResult>> _searchItunes(String query) async {
    final encoded = Uri.encodeComponent(query.trim());
    final url = Uri.parse('https://itunes.apple.com/search?media=podcast&term=$encoded&limit=15&country=US&entity=podcast');
    try {
      final resp = await http.get(url, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (data['results'] as List?) ?? [];
      return list
          .map((e) => PodcastSearchResult.fromItunes(e as Map<String, dynamic>))
          .where((r) => r.feedUrl.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[PodcastService] itunes search error: $e');
      return [];
    }
  }

  Future<List<PodcastSearchResult>> _searchPodster(String query) async {
    try {
      final encoded = Uri.encodeComponent(query.trim());
      final url = Uri.parse('https://podster.fm/search?query=$encoded');
      final htmlBody = await _fetchString(url.toString());
      final m = RegExp(r'data-page="([^"]+)"').firstMatch(htmlBody);
      if (m == null) return [];
      String jstr = m.group(1)!;
      jstr = jstr.replaceAll('&quot;', '"').replaceAll('&amp;', '&').replaceAll('&#039;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>');
      final j = jsonDecode(jstr) as Map<String, dynamic>;
      final props = j['props'] as Map<String, dynamic>?;
      if (props == null) return [];
      final pi = props['podcastsInitial'] as Map<String, dynamic>?;
      if (pi == null) return [];
      final dataList = (pi['data'] as List?) ?? [];
      return dataList.map((e) {
        final map = e as Map<String, dynamic>;
        final cover = map['cover_image'] as Map<String, dynamic>?;
        final art = cover != null ? (cover['xl'] ?? cover['md'] ?? cover['sm'])?.toString() ?? '' : '';
        return PodcastSearchResult(
          trackName: map['name']?.toString() ?? 'Unknown',
          artistName: (map['authors'] as List?)?.isNotEmpty == true ? ((map['authors'] as List).first['name']?.toString() ?? '') : '',
          feedUrl: map['rss_url']?.toString() ?? '',
          artworkUrl: art,
          trackViewUrl: map['show_url']?.toString(),
        );
      }).where((r) => r.feedUrl.isNotEmpty).take(10).toList();
    } catch (e) {
      debugPrint('[PodcastService] podster search error: $e');
      return [];
    }
  }

  Future<List<PodcastSearchResult>> _searchPcSt(String query) async {
    try {
      final encoded = Uri.encodeComponent(query.trim());
      final url = Uri.parse('https://search.pc.st/?q=$encoded');
      final resp = await http.get(url, headers: {'Accept': 'application/json', 'User-Agent': 'KumaFlow/1.0'}).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (data['result'] as List?) ?? [];
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return PodcastSearchResult(
          trackName: m['title']?.toString() ?? 'Unknown',
          artistName: '',
          feedUrl: m['rss']?.toString() ?? '',
          artworkUrl: m['artwork']?.toString() ?? '',
          trackViewUrl: null,
        );
      }).where((r) => r.feedUrl.isNotEmpty).take(10).toList();
    } catch (e) {
      debugPrint('[PodcastService] pc.st search error: $e');
      return [];
    }
  }

  // For Browse: fetch featured from iTunes top or default feeds metadata
  Future<List<Podcast>> getFeaturedPodcasts() async {
    // Try to fetch metadata for default feeds in parallel (best effort)
    final subs = await getSubscriptions();
    if (subs.isNotEmpty) return subs;
    // return stubs for default feeds with placeholder images if not yet fetched
    return defaultFeeds.map((f) {
      return Podcast(
        id: _generateId(f['feedUrl']!),
        title: f['title']!,
        description: '',
        author: f['author']!,
        imageUrl: f['image'],
        feedUrl: f['feedUrl']!,
      );
    }).toList();
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
