import "dart:async";
import "dart:collection";
import "dart:developer" as dev show log;
import "dart:math" show min;
import "dart:typed_data" show ByteData;
import "dart:ui" show Image;

import "package:computer/computer.dart";
import "package:flutter/services.dart" show PlatformException;
import "package:logging/logging.dart";
import "package:photos/core/cache/lru_map.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/embeddings_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/diff_sync_complete_event.dart";
import 'package:photos/events/embedding_updated_event.dart';
import "package:photos/events/file_uploaded_event.dart";
import "package:photos/events/machine_learning_control_event.dart";
import "package:photos/models/embedding.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/ml_versions.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/machine_learning/face_ml/face_clustering/cosine_distance.dart";
import "package:photos/services/machine_learning/ml_result.dart";
import "package:photos/services/machine_learning/semantic_search/clip/clip_image_encoder.dart";
import 'package:photos/services/machine_learning/semantic_search/embedding_store.dart';
import "package:photos/utils/debouncer.dart";
import "package:photos/utils/local_settings.dart";
import "package:photos/utils/ml_util.dart";
// import "package:photos/utils/thumbnail_util.dart";

class SemanticSearchService {
  SemanticSearchService._privateConstructor();

  static final SemanticSearchService instance =
      SemanticSearchService._privateConstructor();
  static final Computer _computer = Computer.shared();
  static final LRUMap<String, List<double>> _queryCache = LRUMap(20);

  static const kEmbeddingLength = 512;
  static const kMinimumSimilarityThreshold = 0.20;
  static const kShouldPushEmbeddings = true;
  static const kDebounceDuration = Duration(milliseconds: 4000);

  final _logger = Logger("SemanticSearchService");
  final _queue = Queue<EnteFile>();
  final _embeddingLoaderDebouncer =
      Debouncer(kDebounceDuration, executionInterval: kDebounceDuration);

  bool _hasInitialized = false;
  bool _isComputingEmbeddings = false;
  bool _isSyncing = false;
  List<Embedding> _cachedEmbeddings = <Embedding>[];
  Future<(String, List<EnteFile>)>? _searchScreenRequest;
  String? _latestPendingQuery;

  Completer<void> _mlController = Completer<void>();

  get hasInitialized => _hasInitialized;

  Future<void> init({bool shouldSyncImmediately = false}) async {
    if (!LocalSettings.instance.hasEnabledMagicSearch()) {
      return;
    }
    if (_hasInitialized) {
      _logger.info("Initialized already");
      return;
    }
    _hasInitialized = true;
    await EmbeddingStore.instance.init();
    await EmbeddingsDB.instance.init();
    await _loadEmbeddings();
    Bus.instance.on<EmbeddingUpdatedEvent>().listen((event) {
      _embeddingLoaderDebouncer.run(() async {
        await _loadEmbeddings();
      });
    });
    Bus.instance.on<DiffSyncCompleteEvent>().listen((event) {
      // Diff sync is complete, we can now pull embeddings from remote
      unawaited(sync());
    });
    if (Configuration.instance.hasConfiguredAccount() &&
        kShouldPushEmbeddings) {
      unawaited(EmbeddingStore.instance.pushEmbeddings());
    }

    // ignore: unawaited_futures
    _loadModels().then((v) async {
      _logger.info("Getting text embedding");
      await _getTextEmbedding("warm up text encoder");
      _logger.info("Got text embedding");
    });
    // Adding to queue only on init?
    Bus.instance.on<FileUploadedEvent>().listen((event) async {
      _addToQueue(event.file);
    });
    if (shouldSyncImmediately) {
      unawaited(sync());
    }
    Bus.instance.on<MachineLearningControlEvent>().listen((event) {
      if (event.shouldRun) {
        _startIndexing();
      } else {
        _pauseIndexing();
      }
    });
  }

  Future<void> sync() async {
    if (_isSyncing) {
      return;
    }
    _isSyncing = true;
    final fetchCompleted = await EmbeddingStore.instance.pullEmbeddings();
    if (fetchCompleted) {
      await _backFill();
    }
    _isSyncing = false;
  }

  bool isMagicSearchEnabledAndReady() {
    return LocalSettings.instance.hasEnabledMagicSearch() &&
        _frameworkInitialization.isCompleted;
  }

  // searchScreenQuery should only be used for the user initiate query on the search screen.
  // If there are multiple call tho this method, then for all the calls, the result will be the same as the last query.
  Future<(String, List<EnteFile>)> searchScreenQuery(String query) async {
    if (!isMagicSearchEnabledAndReady()) {
      return (query, <EnteFile>[]);
    }
    // If there's an ongoing request, just update the last query and return its future.
    if (_searchScreenRequest != null) {
      _latestPendingQuery = query;
      return _searchScreenRequest!;
    } else {
      // No ongoing request, start a new search.
      _searchScreenRequest = getMatchingFiles(query).then((result) {
        // Search completed, reset the ongoing request.
        _searchScreenRequest = null;
        // If there was a new query during the last search, start a new search with the last query.
        if (_latestPendingQuery != null) {
          final String newQuery = _latestPendingQuery!;
          _latestPendingQuery = null; // Reset last query.
          // Recursively call search with the latest query.
          return searchScreenQuery(newQuery);
        }
        return (query, result);
      });
      return _searchScreenRequest!;
    }
  }

  Future<IndexStatus> getIndexStatus() async {
    final indexableFileIDs = await getIndexableFileIDs();
    return IndexStatus(
      min(_cachedEmbeddings.length, indexableFileIDs.length),
      (await _getFileIDsToBeIndexed()).length,
    );
  }

  InitializationState getFrameworkInitializationState() {
    if (!_hasInitialized) {
      return InitializationState.notInitialized;
    }
    return _mlFramework.initializationState;
  }

  Future<void> clearIndexes() async {
    await EmbeddingStore.instance.clearEmbeddings();
    _logger.info("Indexes cleared");
  }

  Future<void> _loadEmbeddings() async {
    _logger.info("Pulling cached embeddings");
    final startTime = DateTime.now();
    _cachedEmbeddings = await EmbeddingsDB.instance.getAll();
    final endTime = DateTime.now();
    _logger.info(
      "Loading ${_cachedEmbeddings.length} took: ${(endTime.millisecondsSinceEpoch - startTime.millisecondsSinceEpoch)}ms",
    );
    Bus.instance.fire(EmbeddingCacheUpdatedEvent());
    _logger.info("Cached embeddings: " + _cachedEmbeddings.length.toString());
  }

  Future<void> _backFill() async {
    if (!LocalSettings.instance.hasEnabledMagicSearch() ||
        !MLFramework.kImageEncoderEnabled) {
      return;
    }
    await _frameworkInitialization.future;
    _logger.info("Attempting backfill for image embeddings");
    final fileIDs = await _getFileIDsToBeIndexed();
    if (fileIDs.isEmpty) {
      return;
    }
    final files = await FilesDB.instance.getUploadedFiles(fileIDs);
    _logger.info(files.length.toString() + " to be embedded");
    // await _cacheThumbnails(files);
    _queue.addAll(files);
    unawaited(_pollQueue());
  }

  Future<List<int>> _getFileIDsToBeIndexed() async {
    final uploadedFileIDs = await getIndexableFileIDs();
    final embeddedFileIDs = await EmbeddingsDB.instance.getIndexedFileIds();
    embeddedFileIDs.removeWhere((key, value) => value < clipMlVersion);

    return uploadedFileIDs.difference(embeddedFileIDs.keys.toSet()).toList();
  }

  Future<void> clearQueue() async {
    _queue.clear();
  }

  Future<List<EnteFile>> getMatchingFiles(
    String query, {
    double? scoreThreshold,
  }) async {
    final textEmbedding = await _getTextEmbedding(query);

    final queryResults = await _getSimilarities(
      textEmbedding,
      minimumSimilarity: scoreThreshold,
    );

    // print query for top ten scores
    for (int i = 0; i < min(10, queryResults.length); i++) {
      final result = queryResults[i];
      dev.log("Query: $query, Score: ${result.score}, index $i");
    }

    final filesMap = await FilesDB.instance
        .getFilesFromIDs(queryResults.map((e) => e.id).toList());

    final ignoredCollections =
        CollectionsService.instance.getHiddenCollectionIds();

    final deletedEntries = <int>[];
    final results = <EnteFile>[];

    for (final result in queryResults) {
      final file = filesMap[result.id];
      if (file != null && !ignoredCollections.contains(file.collectionID)) {
        results.add(file);
      }
      if (file == null) {
        deletedEntries.add(result.id);
      }
    }

    _logger.info(results.length.toString() + " results");

    if (deletedEntries.isNotEmpty) {
      unawaited(EmbeddingsDB.instance.deleteEmbeddings(deletedEntries));
    }

    return results;
  }

  Future<List<int>> getMatchingFileIDs(
    String query,
    double minimumSimilarity,
  ) async {
    final textEmbedding = await _getTextEmbedding(query);

    final queryResults = await _getSimilarities(
      textEmbedding,
      minimumSimilarity: minimumSimilarity,
    );

    final queryResultIds = <int>[];
    for (QueryResult result in queryResults) {
      queryResultIds.add(result.id);
    }

    final filesMap = await FilesDB.instance.getFilesFromIDs(
      queryResultIds,
    );
    final results = <EnteFile>[];

    final ignoredCollections =
        CollectionsService.instance.getHiddenCollectionIds();
    final deletedEntries = <int>[];
    for (final result in queryResults) {
      final file = filesMap[result.id];
      if (file != null && !ignoredCollections.contains(file.collectionID)) {
        results.add(file);
      }
      if (file == null) {
        deletedEntries.add(result.id);
      }
    }

    _logger.info(results.length.toString() + " results");

    if (deletedEntries.isNotEmpty) {
      unawaited(EmbeddingsDB.instance.deleteEmbeddings(deletedEntries));
    }

    final matchingFileIDs = <int>[];
    for (EnteFile file in results) {
      matchingFileIDs.add(file.uploadedFileID!);
    }

    return matchingFileIDs;
  }

  void _addToQueue(EnteFile file) {
    if (!LocalSettings.instance.hasEnabledMagicSearch()) {
      return;
    }
    _logger.info("Adding " + file.toString() + " to the queue");
    _queue.add(file);
    _pollQueue();
  }

  Future<void> _loadModels() async {
    _logger.info("Initializing ML framework");
    try {
      await _mlFramework.init();
      _frameworkInitialization.complete(true);
    } catch (e, s) {
      _logger.severe("ML framework initialization failed", e, s);
    }
    _logger.info("ML framework initialized");
  }

  Future<void> _pollQueue() async {
    if (_isComputingEmbeddings) {
      return;
    }
    _isComputingEmbeddings = true;

    while (_queue.isNotEmpty) {
      await computeImageEmbedding(_queue.removeLast());
    }

    _isComputingEmbeddings = false;
  }

  Future<void> computeImageEmbedding(EnteFile file) async {
    if (!MLFramework.kImageEncoderEnabled) {
      return;
    }
    if (!_frameworkInitialization.isCompleted) {
      return;
    }
    if (!_mlController.isCompleted) {
      _logger.info("Waiting for a green signal from controller...");
      await _mlController.future;
    }
    try {
      // TODO: revert this later
      // final thumbnail = await getThumbnailForUploadedFile(file);
      // if (thumbnail == null) {
      //   _logger.warning("Could not get thumbnail for $file");
      //   return;
      // }
      // final filePath = thumbnail.path;
      final filePath =
          await getImagePathForML(file, typeOfData: FileDataForML.fileData);

      _logger.info("Running clip over $file");
      final result = await _mlFramework.getImageEmbedding(filePath);
      if (result.length != kEmbeddingLength) {
        _logger.severe("Discovered incorrect embedding for $file - $result");
        return;
      }

      final embedding = Embedding(
        fileID: file.uploadedFileID!,
        embedding: result,
      );
      await EmbeddingStore.instance.storeEmbedding(
        file,
        embedding,
      );
    } on FormatException catch (e, _) {
      _logger.severe(
        "Could not get embedding for $file because FormatException occured, storing empty result locally",
        e,
      );
      final embedding = Embedding.empty(file.uploadedFileID!);
      await EmbeddingsDB.instance.put(embedding);
    } on PlatformException catch (e, s) {
      _logger.severe(
        "Could not get thumbnail for $file due to PlatformException related to thumbnails, storing empty result locally",
        e,
        s,
      );
      final embedding = Embedding.empty(file.uploadedFileID!);
      await EmbeddingsDB.instance.put(embedding);
    } catch (e, s) {
      _logger.severe(e, s);
    }
  }

  static Future<void> storeClipImageResult(
    ClipResult clipResult,
    EnteFile entefile,
  ) async {
    final embedding = Embedding(
      fileID: clipResult.fileID,
      embedding: clipResult.embedding,
    );
    await EmbeddingStore.instance.storeEmbedding(
      entefile,
      embedding,
    );
  }

  static Future<void> storeEmptyClipImageResult(EnteFile entefile) async {
    final embedding = Embedding.empty(entefile.uploadedFileID!);
    await EmbeddingsDB.instance.put(embedding);
  }

  Future<List<double>> _getTextEmbedding(String query) async {
    _logger.info("Searching for " + query);
    final cachedResult = _queryCache.get(query);
    if (cachedResult != null) {
      return cachedResult;
    }
    try {
      final result = await _mlFramework.getTextEmbedding(query);
      _queryCache.put(query, result);
      return result;
    } catch (e) {
      _logger.severe("Could not get text embedding", e);
      return [];
    }
  }

  Future<List<QueryResult>> _getSimilarities(
    List<double> textEmbedding, {
    double? minimumSimilarity,
  }) async {
    final startTime = DateTime.now();
    final List<QueryResult> queryResults = await _computer.compute(
      computeBulkSimilarities,
      param: {
        "imageEmbeddings": _cachedEmbeddings,
        "textEmbedding": textEmbedding,
        "minimumSimilarity": minimumSimilarity,
      },
      taskName: "computeBulkScore",
    );
    final endTime = DateTime.now();
    _logger.info(
      "computingScores took: " +
          (endTime.millisecondsSinceEpoch - startTime.millisecondsSinceEpoch)
              .toString() +
          "ms",
    );
    return queryResults;
  }

  void _startIndexing() {
    _logger.info("Start indexing");
    if (!_mlController.isCompleted) {
      _mlController.complete();
    }
  }

  void _pauseIndexing() {
    if (_mlController.isCompleted) {
      _logger.info("Pausing indexing");
      _mlController = Completer<void>();
    }
  }

  static Future<ClipResult> runClipImage(
    int enteFileID,
    Image image,
    ByteData imageByteData,
    int clipImageAddress,
  ) async {
    final embedding =
        await ClipImageEncoder.predict(image, imageByteData, clipImageAddress);
    final clipResult = ClipResult(fileID: enteFileID, embedding: embedding);

    return clipResult;
  }
}

List<QueryResult> computeBulkSimilarities(Map args) {
  final queryResults = <QueryResult>[];
  final imageEmbeddings = args["imageEmbeddings"] as List<Embedding>;
  final textEmbedding = args["textEmbedding"] as List<double>;
  final minimumSimilarity = args["minimumSimilarity"] ??
      SemanticSearchService.kMinimumSimilarityThreshold;
  for (final imageEmbedding in imageEmbeddings) {
    final score = computeCosineSimilarity(
      imageEmbedding.embedding,
      textEmbedding,
    );
    if (score >= minimumSimilarity) {
      queryResults.add(QueryResult(imageEmbedding.fileID, score));
    }
  }

  queryResults.sort((first, second) => second.score.compareTo(first.score));
  return queryResults;
}

class QueryResult {
  final int id;
  final double score;

  QueryResult(this.id, this.score);
}

class IndexStatus {
  final int indexedItems, pendingItems;

  IndexStatus(this.indexedItems, this.pendingItems);
}
