import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/podcast.dart';
import '../services/podcast_service.dart';

class PodcastProvider extends ChangeNotifier {
  final PodcastService _service = PodcastService();

  List<Podcast> _subscriptions = [];
  List<Podcast> _featured = [];
  List<PodcastSearchResult> _searchResults = [];
  final Map<String, List<PodcastEpisode>> _episodesCache = {};
  bool _isLoading = false;
  bool _isSearching = false;
  String? _error;

  List<Podcast> get subscriptions => _subscriptions;
  List<Podcast> get featured => _featured;
  List<PodcastSearchResult> get searchResults => _searchResults;
  bool get isLoading => _isLoading;
  bool get isSearching => _isSearching;
  String? get error => _error;

  List<Podcast> get allPodcasts {
    if (_subscriptions.isNotEmpty) return _subscriptions;
    return _featured;
  }

  PodcastProvider() {
    _init();
  }

  Future<void> _init() async {
    await loadSubscriptions();
    await loadFeatured();
  }

  Future<void> loadSubscriptions() async {
    _isLoading = true;
    notifyListeners();
    try {
      _subscriptions = await _service.getSubscriptions();
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadFeatured() async {
    try {
      _featured = await _service.getFeaturedPodcasts();
      notifyListeners();
    } catch (_) {}
  }

  Future<bool> addFeed(String feedUrl) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await _service.fetchPodcast(feedUrl);
      await _service.addSubscription(res.podcast);
      await _service.cacheEpisodes(res.podcast.id, res.episodes);
      _episodesCache[res.podcast.id] = res.episodes;
      _subscriptions = await _service.getSubscriptions();
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> removePodcast(String id) async {
    final existing = _subscriptions.where((p) => p.id == id).firstOrNull ??
        _featured.where((p) => p.id == id).firstOrNull;
    final feedUrl = existing?.feedUrl;
    // Also try to find by feedUrl in subscriptions if id is stub
    String? effectiveFeedUrl = feedUrl;
    if (effectiveFeedUrl == null) {
      // maybe id is stub from search — look up stub's feedUrl via searchResults?
      final stub = _searchResults.where((r) => r.toPodcastStub().id == id).firstOrNull;
      effectiveFeedUrl = stub?.feedUrl;
    }
    await _service.removeSubscription(id, feedUrl: effectiveFeedUrl);
    // Also remove by feedUrl from in-memory list (covers deterministic id mismatch)
    if (effectiveFeedUrl != null) {
      _subscriptions.removeWhere((p) => p.feedUrl == effectiveFeedUrl);
    }
    _subscriptions.removeWhere((p) => p.id == id);
    _episodesCache.remove(id);
    if (effectiveFeedUrl != null) {
      // clear any cache keyed by discovered id
      final keysToRemove = _episodesCache.keys.where((k) => _subscriptions.any((p) => p.id == k && p.feedUrl == effectiveFeedUrl)).toList();
      for (final k in keysToRemove) {
        _episodesCache.remove(k);
      }
    }
    // Reload from disk to guarantee consistency
    _subscriptions = await _service.getSubscriptions();
    notifyListeners();
  }

  Future<List<PodcastEpisode>> loadEpisodes(Podcast podcast) async {
    // try cache first
    if (_episodesCache.containsKey(podcast.id)) return _episodesCache[podcast.id]!;
    final cached = await _service.getCachedEpisodes(podcast.id);
    if (cached.isNotEmpty) {
      _episodesCache[podcast.id] = cached;
      // still try refresh in background but return cache immediately
      // ignore: unawaited_futures
      _service.fetchPodcast(podcast.feedUrl).then((res) async {
        await _service.cacheEpisodes(podcast.id, res.episodes);
        _episodesCache[podcast.id] = res.episodes;
        notifyListeners();
      }).catchError((e) {
        debugPrint('[Podcast] background refresh failed: $e');
      });
      return cached;
    }
    // fetch fresh with localized timeout handling
    try {
      final res = await _service.fetchPodcast(podcast.feedUrl);
      await _service.cacheEpisodes(res.podcast.id, res.episodes);
      // also cache under original id for quick lookup
      await _service.cacheEpisodes(podcast.id, res.episodes);
      _episodesCache[podcast.id] = res.episodes;
      final updated = podcast.copyWith(episodeCount: res.episodes.length);
      await _service.updateSubscription(updated);
      final idx = _subscriptions.indexWhere((p) => p.id == podcast.id || p.feedUrl == podcast.feedUrl);
      if (idx != -1) _subscriptions[idx] = updated;
      notifyListeners();
      return res.episodes;
    } catch (e) {
      String msg = e.toString();
      if (e is TimeoutException || msg.contains('TimeoutException') || msg.contains('превышено время')) {
        msg = 'Не удалось загрузить подкаст: превышено время ожидания (проверьте интернет или попробуйте позже)';
      } else if (msg.contains('HTTP')) {
        msg = 'Ошибка загрузки подкаста: $msg';
      }
      _error = msg;
      notifyListeners();
      // Return cached if any even on error (may be stale but better than empty)
      final fallback = await _service.getCachedEpisodes(podcast.id);
      if (fallback.isNotEmpty) return fallback;
      return [];
    }
  }

  Future<void> search(String query) async {
    if (query.trim().isEmpty) {
      _searchResults = [];
      notifyListeners();
      return;
    }
    _isSearching = true;
    notifyListeners();
    try {
      _searchResults = await _service.searchPodcasts(query);
      _error = null;
    } catch (e) {
      _error = e.toString();
      _searchResults = [];
    }
    _isSearching = false;
    notifyListeners();
  }

  void clearSearch() {
    _searchResults = [];
    notifyListeners();
  }

  bool isSubscribed(String feedUrl) => _subscriptions.any((p) => p.feedUrl == feedUrl);
  bool isSubscribedId(String id) => _subscriptions.any((p) => p.id == id);
  bool isPodcastSubscribed(Podcast p) => _subscriptions.any((e) => e.id == p.id || e.feedUrl == p.feedUrl);
}
