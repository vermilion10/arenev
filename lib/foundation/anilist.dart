import 'dart:math';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

/// AniList OAuth client id of venera.
///
/// The redirect url of the client is set to
/// `https://anilist.co/api/v2/oauth/pin`, which makes AniList show the access
/// token to the user instead of redirecting to a server. The user then pastes
/// the token into the app.
const _aniListClientId = "51300";

/// The url the user opens to get an access token.
const aniListAuthorizeUrl =
    "https://anilist.co/api/v2/oauth/authorize"
    "?client_id=$_aniListClientId&response_type=token";

const _aniListApiUrl = "https://graphql.anilist.co";

/// Thrown by [AniListManager] when a request cannot be completed.
class AniListException implements Exception {
  final String message;

  /// Whether the token is missing or rejected, so the user has to connect
  /// the account again.
  final bool requiresAuth;

  const AniListException(this.message, {this.requiresAuth = false});

  @override
  String toString() => message;
}

/// A manga entry on AniList.
class AniListMedia {
  final int id;

  final String? romajiTitle;

  final String? englishTitle;

  final String? nativeTitle;

  final String? cover;

  /// Total chapter count. Null if AniList does not know it yet.
  final int? chapters;

  final String? status;

  const AniListMedia({
    required this.id,
    this.romajiTitle,
    this.englishTitle,
    this.nativeTitle,
    this.cover,
    this.chapters,
    this.status,
  });

  /// The title used for display.
  String get title =>
      romajiTitle ?? englishTitle ?? nativeTitle ?? "AniList #$id";

  List<String> get allTitles => [
        if (romajiTitle != null) romajiTitle!,
        if (englishTitle != null) englishTitle!,
        if (nativeTitle != null) nativeTitle!,
      ];

  static AniListMedia fromJson(Map<String, dynamic> json) {
    var title = json["title"] as Map<String, dynamic>? ?? const {};
    return AniListMedia(
      id: json["id"] as int,
      romajiTitle: title["romaji"] as String?,
      englishTitle: title["english"] as String?,
      nativeTitle: title["native"] as String?,
      cover: (json["coverImage"] as Map<String, dynamic>?)?["medium"]
          as String?,
      chapters: json["chapters"] as int?,
      status: json["status"] as String?,
    );
  }
}

/// A link between a comic in the app and a manga entry on AniList.
class AniListLink {
  final String sourceKey;

  final String comicId;

  final int mediaId;

  /// Cached AniList title, so the link can be displayed without a request.
  final String title;

  final int? totalChapters;

  /// The progress which was already pushed to AniList.
  final int lastSyncedProgress;

  final DateTime createdAt;

  const AniListLink({
    required this.sourceKey,
    required this.comicId,
    required this.mediaId,
    required this.title,
    this.totalChapters,
    this.lastSyncedProgress = 0,
    required this.createdAt,
  });

  AniListLink.fromRow(Row row)
      : sourceKey = row["source_key"] as String,
        comicId = row["comic_id"] as String,
        mediaId = row["anilist_media_id"] as int,
        title = row["title"] as String,
        totalChapters = row["total_chapters"] as int?,
        lastSyncedProgress = row["last_synced_progress"] as int? ?? 0,
        createdAt =
            DateTime.fromMillisecondsSinceEpoch(row["created_at"] as int);
}

class AniListManager with ChangeNotifier {
  static AniListManager? cache;

  AniListManager.create();

  factory AniListManager() =>
      cache == null ? (cache = AniListManager.create()) : cache!;

  late Database _db;

  bool isInitialized = false;

  /// All links, keyed by [_key]. The number of links is small, so keeping
  /// them in memory avoids a query on every reading progress update.
  final _links = <String, AniListLink>{};

  static String _key(String sourceKey, String comicId) =>
      "$sourceKey@$comicId";

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _db = sqlite3.open("${App.dataPath}/anilist.db");
    _db.execute("""
        create table if not exists links (
          source_key text not null,
          comic_id text not null,
          anilist_media_id int not null,
          title text not null,
          total_chapters int,
          last_synced_progress int not null default 0,
          created_at int not null,
          primary key (source_key, comic_id)
        );
      """);
    _loadLinks();
    isInitialized = true;
  }

  void _loadLinks() {
    _links.clear();
    for (var row in _db.select("select * from links;")) {
      var link = AniListLink.fromRow(row);
      _links[_key(link.sourceKey, link.comicId)] = link;
    }
  }

  bool get isLoggedIn => token != null;

  /// The AniList access token, or null if the user did not connect an account.
  String? get token {
    var value = appdata.settings['anilistToken'];
    if (value is! String || value.isEmpty) {
      return null;
    }
    return value;
  }

  set token(String? value) {
    appdata.settings['anilistToken'] = value ?? '';
    appdata.saveData();
  }

  AniListLink? find(String sourceKey, String comicId) {
    return _links[_key(sourceKey, comicId)];
  }

  List<AniListLink> getAll() => _links.values.toList();

  void link(AniListLink link) {
    _db.execute("""
      insert or replace into links
        (source_key, comic_id, anilist_media_id, title, total_chapters,
         last_synced_progress, created_at)
      values (?, ?, ?, ?, ?, ?, ?);
    """, [
      link.sourceKey,
      link.comicId,
      link.mediaId,
      link.title,
      link.totalChapters,
      link.lastSyncedProgress,
      link.createdAt.millisecondsSinceEpoch,
    ]);
    _links[_key(link.sourceKey, link.comicId)] = link;
    notifyListeners();
  }

  void unlink(String sourceKey, String comicId) {
    _db.execute("""
      delete from links where source_key == ? and comic_id == ?;
    """, [sourceKey, comicId]);
    _links.remove(_key(sourceKey, comicId));
    notifyListeners();
  }

  void setSyncedProgress(String sourceKey, String comicId, int progress) {
    var current = find(sourceKey, comicId);
    if (current == null) {
      return;
    }
    _db.execute("""
      update links set last_synced_progress = ?
      where source_key == ? and comic_id == ?;
    """, [progress, sourceKey, comicId]);
    _links[_key(sourceKey, comicId)] = AniListLink(
      sourceKey: current.sourceKey,
      comicId: current.comicId,
      mediaId: current.mediaId,
      title: current.title,
      totalChapters: current.totalChapters,
      lastSyncedProgress: progress,
      createdAt: current.createdAt,
    );
    notifyListeners();
  }

  void close() {
    isInitialized = false;
    _links.clear();
    _db.dispose();
  }

  Future<Map<String, dynamic>> _request(
    String query,
    Map<String, dynamic> variables, {
    bool authenticated = true,
  }) async {
    var accessToken = token;
    if (authenticated && accessToken == null) {
      throw AniListException(
        "AniList account is not connected".tl,
        requiresAuth: true,
      );
    }
    Response<Map<String, dynamic>> res;
    try {
      res = await AppDio().post<Map<String, dynamic>>(
        _aniListApiUrl,
        data: {"query": query, "variables": variables},
        options: Options(
          headers: {
            if (authenticated) "Authorization": "Bearer $accessToken",
            "Content-Type": "application/json",
            "Accept": "application/json",
          },
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (e) {
      var statusCode = e.response?.statusCode;
      if (authenticated && statusCode == 401) {
        throw AniListException(
          "AniList authorization failed. Please connect your account again.".tl,
          requiresAuth: true,
        );
      }
      throw AniListException(_errorMessage(e.response?.data) ??
          e.message ??
          e.toString());
    }
    var data = res.data;
    if (data == null) {
      throw AniListException("Invalid response from AniList".tl);
    }
    var error = _errorMessage(data);
    if (error != null) {
      throw AniListException(error);
    }
    var payload = data["data"];
    if (payload is! Map<String, dynamic>) {
      throw AniListException("Invalid response from AniList".tl);
    }
    return payload;
  }

  /// Extract the first message of a GraphQL `errors` array, if there is one.
  static String? _errorMessage(dynamic body) {
    if (body is! Map) {
      return null;
    }
    var errors = body["errors"];
    if (errors is! List || errors.isEmpty) {
      return null;
    }
    var first = errors.first;
    if (first is Map && first["message"] != null) {
      return first["message"].toString();
    }
    return null;
  }

  static const _searchQuery = """
    query (\$search: String, \$perPage: Int) {
      Page(page: 1, perPage: \$perPage) {
        media(search: \$search, type: MANGA) {
          id
          title { romaji english native }
          coverImage { medium }
          chapters
          status
        }
      }
    }
  """;

  /// Search manga on AniList. Does not require an access token.
  Future<List<AniListMedia>> search(String title, {int perPage = 5}) async {
    if (title.trim().isEmpty) {
      return const [];
    }
    var data = await _request(
      _searchQuery,
      {"search": title, "perPage": perPage},
      authenticated: false,
    );
    var media = (data["Page"]?["media"] as List?) ?? const [];
    return media
        .map((e) => AniListMedia.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static const _updateProgressMutation = """
    mutation (\$mediaId: Int, \$status: MediaListStatus, \$progress: Int) {
      SaveMediaListEntry(mediaId: \$mediaId, status: \$status, progress: \$progress) {
        id
        status
        progress
      }
    }
  """;

  /// Push reading progress to AniList.
  ///
  /// [status] is omitted when it cannot be determined.
  Future<void> updateProgress(
    int mediaId,
    int progress, {
    String? status,
  }) async {
    await _request(_updateProgressMutation, {
      "mediaId": mediaId,
      "progress": progress,
      if (status != null) "status": status,
    });
  }

  static const _viewerQuery = "query { Viewer { id name } }";

  /// Check the stored token and return the AniList user name.
  Future<String> verifyToken() async {
    var data = await _request(_viewerQuery, const {});
    var name = data["Viewer"]?["name"] as String?;
    if (name == null) {
      throw AniListException(
        "AniList authorization failed. Please connect your account again.".tl,
        requiresAuth: true,
      );
    }
    return name;
  }

  /// The status to report for [progress], or null when it cannot be
  /// determined because the total chapter count is unknown.
  static String? statusForProgress(int progress, int? totalChapters) {
    if (totalChapters == null || totalChapters <= 0) {
      return null;
    }
    return progress >= totalChapters ? "COMPLETED" : "CURRENT";
  }

  /// Pick the best match for [title] among [candidates].
  ///
  /// Returns null when no candidate is similar enough to be used without
  /// asking the user.
  static AniListMedia? bestMatch(
    String title,
    List<AniListMedia> candidates, {
    double threshold = 0.85,
  }) {
    AniListMedia? best;
    var bestScore = 0.0;
    for (var candidate in candidates) {
      for (var candidateTitle in candidate.allTitles) {
        var score = titleSimilarity(title, candidateTitle);
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
    }
    return bestScore >= threshold ? best : null;
  }

  /// Similarity of two titles, from 0 (unrelated) to 1 (equal after
  /// normalization).
  static double titleSimilarity(String a, String b) {
    var normalizedA = _normalizeTitle(a);
    var normalizedB = _normalizeTitle(b);
    if (normalizedA.isEmpty || normalizedB.isEmpty) {
      return 0;
    }
    if (normalizedA == normalizedB) {
      return 1;
    }
    var distance = _levenshtein(normalizedA, normalizedB);
    var longest = max(normalizedA.length, normalizedB.length);
    return 1 - distance / longest;
  }

  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static String _normalizeTitle(String title) {
    var result = StringBuffer();
    var lastWasSpace = true;
    for (var rune in title.toLowerCase().runes) {
      var char = String.fromCharCode(rune);
      if (_letterOrDigit.hasMatch(char)) {
        result.write(char);
        lastWasSpace = false;
      } else if (!lastWasSpace) {
        // Collapse punctuation and whitespace into a single separator.
        result.write(' ');
        lastWasSpace = true;
      }
    }
    return result.toString().trim();
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        var cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        current[j + 1] = min(
          min(current[j] + 1, previous[j + 1] + 1),
          previous[j] + cost,
        );
      }
      var temp = previous;
      previous = current;
      current = temp;
    }
    return previous[b.length];
  }
}

/// Pushes reading progress to AniList in the background.
///
/// Reading progress updates are frequent, so a request is only sent when the
/// chapter index moves past the progress which was last pushed.
class AniListSyncService {
  static AniListSyncService? cache;

  AniListSyncService.create();

  factory AniListSyncService() =>
      cache == null ? (cache = AniListSyncService.create()) : cache!;

  bool _isListening = false;

  /// Comics with a request in flight, keyed the same way as the links.
  final _syncing = <String>{};

  void start() {
    if (_isListening) {
      return;
    }
    _isListening = true;
    HistoryManager().addListener(_onHistoryChanged);
  }

  void stop() {
    if (!_isListening) {
      return;
    }
    _isListening = false;
    HistoryManager().removeListener(_onHistoryChanged);
  }

  void _onHistoryChanged() {
    if (!AniListManager().isInitialized || !AniListManager().isLoggedIn) {
      return;
    }
    // Only the recently modified records can have new progress.
    for (var history in HistoryManager().cachedHistories.values.toList()) {
      syncHistory(history);
    }
  }

  /// Push the progress of [history] to AniList if the comic is linked and
  /// the progress moved forward. Does nothing otherwise.
  void syncHistory(History history) async {
    var sourceKey = history.sourceKey;
    var link = AniListManager().find(sourceKey, history.id);
    if (link == null) {
      return;
    }
    if (history.group != null && history.group != 1) {
      // For grouped chapters, [History.ep] is the index inside the group, so
      // it only matches the chapter number of the first group. There is no
      // reliable chapter number for the other groups, and pushing a wrong one
      // is worse than pushing nothing.
      return;
    }
    var progress = history.ep;
    if (progress <= link.lastSyncedProgress) {
      return;
    }
    var key = "$sourceKey@${history.id}";
    if (_syncing.contains(key)) {
      return;
    }
    _syncing.add(key);
    try {
      await AniListManager().updateProgress(
        link.mediaId,
        progress,
        status: AniListManager.statusForProgress(
          progress,
          link.totalChapters,
        ),
      );
      AniListManager().setSyncedProgress(sourceKey, history.id, progress);
    } catch (e, s) {
      // Syncing happens while reading, so failures are logged instead of
      // being shown to the user.
      Log.error("AniList", "Failed to sync progress: $e", s);
    } finally {
      _syncing.remove(key);
    }
  }
}
