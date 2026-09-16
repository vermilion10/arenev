part of 'comic_page.dart';

abstract mixin class _ComicPageActions {
  void update();

  ComicDetails get comic;

  ComicSource get comicSource => ComicSource.find(comic.sourceKey)!;

  History? get history;

  bool isLiking = false;

  bool isLiked = false;

  void likeOrUnlike() async {
    if (isLiking) return;
    isLiking = true;
    update();
    var res = await comicSource.likeOrUnlikeComic!(comic.id, isLiked);
    if (res.error) {
      App.rootContext.showMessage(message: res.errorMessage!);
    } else {
      isLiked = !isLiked;
    }
    isLiking = false;
    update();
  }

  /// whether the comic is added to local favorite
  bool isAddToLocalFav = false;

  /// whether the comic is favorite on the server
  bool isFavorite = false;

  FavoriteItem _toFavoriteItem() {
    var tags = <String>[];
    for (var e in comic.tags.entries) {
      tags.addAll(e.value.map((tag) => '${e.key}:$tag'));
    }
    return FavoriteItem(
      id: comic.id,
      name: comic.title,
      coverPath: comic.cover,
      author: comic.subTitle ?? comic.uploader ?? '',
      type: comic.comicType,
      tags: tags,
    );
  }

  void openFavPanel() {
    showSideBar(
      App.rootContext,
      _FavoritePanel(
        cid: comic.id,
        type: comic.comicType,
        isFavorite: isFavorite,
        onFavorite: (local, network) {
          if (network != null) {
            isFavorite = network;
          }
          if (local != null) {
            isAddToLocalFav = local;
          }
          update();
        },
        favoriteItem: _toFavoriteItem(),
        updateTime: comic.findUpdateTime(),
      ),
    );
  }

  void quickFavorite() {
    var folder = appdata.settings['quickFavorite'];
    if (folder is! String) {
      return;
    }
    LocalFavoritesManager().addComic(
      folder,
      _toFavoriteItem(),
      null,
      comic.findUpdateTime(),
    );
    isAddToLocalFav = true;
    update();
    App.rootContext.showMessage(message: "Added".tl);
  }

  void share() {
    var text = comic.title;
    if (comic.url != null) {
      text += '\n${comic.url}';
    }
    Share.shareText(text);
  }

  /// read the comic
  ///
  /// [ep] the episode number, start from 1
  ///
  /// [page] the page number, start from 1
  ///
  /// [group] the chapter group number, start from 1
  void read([int? ep, int? page, int? group]) {
    App.rootContext
        .to(
      () => Reader(
        type: comic.comicType,
        cid: comic.id,
        name: comic.title,
        chapters: comic.chapters,
        initialChapter: ep,
        initialPage: page,
        initialChapterGroup: group,
        history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
        author: comic.findAuthor() ?? '',
        tags: comic.plainTags,
      )
    )
        .then((_) {
      onReadEnd();
    });
  }

  void continueRead() {
    var ep = history?.ep ?? 1;
    var page = history?.page ?? 1;
    var group = history?.group ?? 1;
    read(ep, page, group);
  }

  void onReadEnd();

  void download() async {
    if (LocalManager().isDownloading(comic.id, comic.comicType)) {
      App.rootContext.showMessage(message: "The comic is downloading".tl);
      return;
    }
    if (comic.chapters == null &&
        LocalManager().isDownloaded(comic.id, comic.comicType, 0)) {
      App.rootContext.showMessage(message: "The comic is downloaded".tl);
      return;
    }

    if (comicSource.archiveDownloader != null) {
      bool useNormalDownload = false;
      List<ArchiveInfo>? archives;
      int selected = -1;
      bool isLoading = false;
      bool isGettingLink = false;
      await showDialog(
        context: App.rootContext,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setState) {
              return ContentDialog(
                title: "Download".tl,
                content: RadioGroup<int>(
                  groupValue: selected,
                  onChanged: (v) {
                    setState(() {
                      selected = v ?? selected;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<int>(
                        value: -1,
                        title: Text("Normal".tl),
                      ),
                      ExpansionTile(
                        title: Text("Archive".tl),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        collapsedShape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        onExpansionChanged: (b) {
                          if (!isLoading && b && archives == null) {
                            isLoading = true;
                            comicSource.archiveDownloader!
                                .getArchives(comic.id)
                                .then((value) {
                              if (value.success) {
                                archives = value.data;
                              } else {
                                App.rootContext
                                    .showMessage(message: value.errorMessage!);
                              }
                              setState(() {
                                isLoading = false;
                              });
                            });
                          }
                        },
                        children: [
                          if (archives == null)
                            const ListLoadingIndicator().toCenter()
                          else
                            for (int i = 0; i < archives!.length; i++)
                              RadioListTile<int>(
                                value: i,
                                title: Text(archives![i].title),
                                subtitle: Text(archives![i].description),
                              )
                        ],
                      )
                    ],
                  ),
                ),
                actions: [
                  Button.filled(
                    isLoading: isGettingLink,
                    onPressed: () async {
                      if (selected == -1) {
                        useNormalDownload = true;
                        context.pop();
                        return;
                      }
                      setState(() {
                        isGettingLink = true;
                      });
                      var res =
                          await comicSource.archiveDownloader!.getDownloadUrl(
                        comic.id,
                        archives![selected].id,
                      );
                      if (res.error) {
                        App.rootContext.showMessage(message: res.errorMessage!);
                        setState(() {
                          isGettingLink = false;
                        });
                      } else if (context.mounted) {
                        if (res.data.isNotEmpty) {
                          LocalManager()
                            .addTask(ArchiveDownloadTask(res.data, comic));
                          App.rootContext
                            .showMessage(message: "Download started".tl);
                        }
                        context.pop();
                      }
                    },
                    child: Text("Confirm".tl),
                  ),
                ],
              );
            },
          );
        },
      );
      if (!useNormalDownload) {
        return;
      }
    }

    if (comic.chapters == null) {
      LocalManager().addTask(ImagesDownloadTask(
        source: comicSource,
        comicId: comic.id,
        comic: comic,
      ));
    } else {
      List<int>? selected;
      var downloaded = <int>[];
      var localComic = LocalManager().find(comic.id, comic.comicType);
      if (localComic != null) {
        for (int i = 0; i < comic.chapters!.length; i++) {
          if (localComic.downloadedChapters
              .contains(comic.chapters!.ids.elementAt(i))) {
            downloaded.add(i);
          }
        }
      }
      await showSideBar(
        App.rootContext,
        _SelectDownloadChapter(
          comic.chapters!.titles.toList(),
          (v) => selected = v,
          downloaded,
        ),
      );
      if (selected == null) return;
      LocalManager().addTask(ImagesDownloadTask(
        source: comicSource,
        comicId: comic.id,
        comic: comic,
        chapters: selected!.map((i) {
          return comic.chapters!.ids.elementAt(i);
        }).toList(),
      ));
    }
    App.rootContext.showMessage(message: "Download started".tl);
    update();
  }

  /// Download the comic (or the selected chapters) directly into a single
  /// pdf file. Images are streamed into a scratch directory in the cache and
  /// removed afterwards, so nothing is added to the local comic library.
  void downloadAsPdf() async {
    List<String>? chapterIds;
    if (comic.chapters != null) {
      List<int>? selected;
      await showSideBar(
        App.rootContext,
        _SelectDownloadChapter(
          comic.chapters!.titles.toList(),
          (v) => selected = v,
          const [],
        ),
      );
      if (selected == null || selected!.isEmpty) {
        return;
      }
      chapterIds = selected!.map((i) {
        return comic.chapters!.ids.elementAt(i);
      }).toList();
    }

    var scratchDir = Directory(FilePath.join(
      App.cachePath,
      'pdf_direct_download',
      sanitizeFileName(comic.id, maxLength: 64),
    ));
    var canceled = false;
    var loadingController = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      message: "Fetching image list...".tl,
      withProgress: true,
      onCancel: () {
        canceled = true;
      },
    );

    try {
      scratchDir.forceCreateSync();

      var pages = <({String chapter, String image})>[];
      if (chapterIds == null) {
        var images = await _loadPagesWithRetry(null);
        pages.addAll(images.map((e) => (chapter: '', image: e)));
      } else {
        for (var i = 0; i < chapterIds.length; i++) {
          if (canceled) return;
          loadingController.setMessage(
            "${"Fetching image list".tl} ${i + 1}/${chapterIds.length}",
          );
          var images = await _loadPagesWithRetry(chapterIds[i]);
          pages.addAll(
            images.map((e) => (chapter: chapterIds![i], image: e)),
          );
        }
      }
      if (canceled) return;
      if (pages.isEmpty) {
        throw "No images to download".tl;
      }

      var total = pages.length;
      var imagePaths = List<String?>.filled(total, null);
      var downloaded = 0;
      loadingController.setMessage("$downloaded/$total");
      loadingController.setProgress(0);

      var maxConcurrentTasks =
          (appdata.settings["downloadThreads"] as num).toInt();
      if (maxConcurrentTasks < 1) {
        maxConcurrentTasks = 1;
      }
      var next = 0;
      Object? error;

      Future<void> runWorker() async {
        while (true) {
          if (canceled || error != null) return;
          var i = next++;
          if (i >= total) return;
          try {
            imagePaths[i] = await _downloadImageToFile(
              image: pages[i].image,
              sourceKey: comicSource.key,
              comicId: comic.id,
              chapter: pages[i].chapter,
              saveTo: scratchDir,
              name: i.toString(),
              isCanceled: () => canceled,
            );
          } catch (e) {
            error ??= e;
            return;
          }
          downloaded++;
          loadingController.setMessage("$downloaded/$total");
          loadingController.setProgress(downloaded / total);
        }
      }

      await Future.wait(List.generate(
        maxConcurrentTasks > total ? total : maxConcurrentTasks,
        (_) => runWorker(),
      ));

      if (canceled) return;
      if (error != null) {
        throw error!;
      }

      loadingController.setProgress(null);
      loadingController.setMessage("Generating pdf...".tl);
      var fileName = "${sanitizeFileName(comic.title, maxLength: 100)}.pdf";
      var pdfPath = FilePath.join(scratchDir.path, fileName);
      await createPdfFromImagesIsolate(
        imagePaths.map((e) => e!).toList(),
        title: comic.title,
        author: comic.subTitle ?? '',
        savePath: pdfPath,
      );
      if (canceled) return;
      loadingController.close();
      await saveFile(file: File(pdfPath), filename: fileName);
    } catch (e, s) {
      Log.error("Download", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    } finally {
      loadingController.close();
      await scratchDir.deleteIgnoreError(recursive: true);
    }
  }

  Future<List<String>> _loadPagesWithRetry(String? chapter) {
    return _runWithRetry(() async {
      var res = await comicSource.loadComicPages!(comic.id, chapter);
      if (res.error) {
        throw res.errorMessage!;
      }
      return res.data;
    });
  }

  /// Link this comic to an AniList entry, or manage an existing link.
  ///
  /// When the comic is not linked yet, AniList is searched by title. A
  /// confident match is applied directly, anything else opens the picker.
  void trackOnAniList() async {
    if (!AniListManager().isLoggedIn) {
      App.rootContext.showMessage(
        message: "Connect your AniList account in settings first".tl,
      );
      return;
    }

    if (AniListManager().find(comic.sourceKey, comic.id) != null) {
      await _showAniListPanel();
      return;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      allowCancel: false,
      message: "Searching on AniList...".tl,
    );
    List<AniListMedia> results;
    try {
      results = await AniListManager().search(comic.title);
    } catch (e, s) {
      loadingController.close();
      Log.error("AniList", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
      return;
    }
    loadingController.close();

    var match = AniListManager.bestMatch(comic.title, results);
    if (match == null) {
      // No confident match, let the user pick.
      await _showAniListPanel();
      return;
    }

    _linkToAniList(match);
    var changeMatch = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Linked to AniList".tl,
          content: Text(
            "This comic is now tracked as @name".tlParams({
              "name": match.title,
            }),
          ).paddingHorizontal(16).paddingVertical(8),
          actions: [
            Button.normal(
              onPressed: () {
                changeMatch = true;
                context.pop();
              },
              child: Text("Not this one".tl),
            ),
            Button.filled(
              onPressed: () => context.pop(),
              child: Text("OK".tl),
            ),
          ],
        );
      },
    );
    if (changeMatch) {
      await _showAniListPanel();
    }
  }

  void _linkToAniList(AniListMedia media) {
    AniListManager().link(AniListLink(
      sourceKey: comic.sourceKey,
      comicId: comic.id,
      mediaId: media.id,
      title: media.title,
      totalChapters: media.chapters,
      createdAt: DateTime.now(),
    ));
    _pushCurrentProgressToAniList();
    update();
  }

  /// Push the progress which was already reached before linking, so the
  /// AniList entry does not wait for the next chapter to catch up.
  void _pushCurrentProgressToAniList() {
    var current = history;
    if (current != null) {
      AniListSyncService().syncHistory(current);
    }
  }

  Future<void> _showAniListPanel() {
    return showSideBar(
      App.rootContext,
      _AniListPanel(
        sourceKey: comic.sourceKey,
        comicId: comic.id,
        initialSearch: comic.title,
        onChanged: () {
          _pushCurrentProgressToAniList();
          update();
        },
      ),
    );
  }

  void onTapTag(String tag, String namespace) {
    var target = comicSource.handleClickTagEvent?.call(namespace, tag);
    var context = App.mainNavigatorKey!.currentContext!;
    target?.jump(context);
  }

  void showMoreActions() {
    var context = App.rootContext;
    showMenuX(
        context,
        Offset(
          context.width - 16,
          context.padding.top,
        ),
        [
          MenuEntry(
            icon: Icons.picture_as_pdf_outlined,
            text: "Download as PDF".tl,
            onClick: downloadAsPdf,
          ),
          MenuEntry(
            icon: Icons.sync_alt,
            text: AniListManager().find(comic.sourceKey, comic.id) == null
                ? "Track on AniList".tl
                : "AniList tracking".tl,
            onClick: trackOnAniList,
          ),
          MenuEntry(
            icon: Icons.copy,
            text: "Copy Title".tl,
            onClick: () {
              Clipboard.setData(ClipboardData(text: comic.title));
              context.showMessage(message: "Copied".tl);
            },
          ),
          MenuEntry(
            icon: Icons.copy_rounded,
            text: "Copy ID".tl,
            onClick: () {
              Clipboard.setData(ClipboardData(text: comic.id));
              context.showMessage(message: "Copied".tl);
            },
          ),
          if (comic.url != null)
            MenuEntry(
              icon: Icons.link,
              text: "Copy URL".tl,
              onClick: () {
                Clipboard.setData(ClipboardData(text: comic.url!));
                context.showMessage(message: "Copied".tl);
              },
            ),
          if (comic.url != null)
            MenuEntry(
              icon: Icons.open_in_browser,
              text: "Open in Browser".tl,
              onClick: () {
                launchUrlString(comic.url!);
              },
            ),
        ]);
  }

  void showComments() {
    showSideBar(
      App.rootContext,
      CommentsPage(
        data: comic,
        source: comicSource,
      ),
    );
  }

  void starRating() {
    if (!comicSource.isLogged) {
      return;
    }
    var rating = 0.0;
    var isLoading = false;
    showDialog(
      context: App.rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => SimpleDialog(
          title: const Text("Rating"),
          alignment: Alignment.center,
          children: [
            SizedBox(
              height: 100,
              child: Center(
                child: SizedBox(
                  width: 210,
                  child: Column(
                    children: [
                      const SizedBox(
                        height: 10,
                      ),
                      RatingWidget(
                        padding: 2,
                        onRatingUpdate: (value) => rating = value,
                        value: 1,
                        selectable: true,
                        size: 40,
                      ),
                      const Spacer(),
                      Button.filled(
                        isLoading: isLoading,
                        onPressed: () {
                          setState(() {
                            isLoading = true;
                          });
                          comicSource.starRatingFunc!(comic.id, rating.round())
                              .then((value) {
                            if (value.success) {
                              App.rootContext
                                  .showMessage(message: "Success".tl);
                              Navigator.of(dialogContext).pop();
                            } else {
                              App.rootContext
                                  .showMessage(message: value.errorMessage!);
                              setState(() {
                                isLoading = false;
                              });
                            }
                          });
                        },
                        child: Text("Submit".tl),
                      )
                    ],
                  ),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}

Future<T> _runWithRetry<T>(Future<T> Function() task, {int retry = 3}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return await task();
    } catch (e) {
      if (i == retry - 1) {
        rethrow;
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

/// Download a single comic image into [saveTo]. Retries the same number of
/// times as the normal download task before giving up.
Future<String> _downloadImageToFile({
  required String image,
  required String sourceKey,
  required String comicId,
  required String chapter,
  required Directory saveTo,
  required String name,
  required bool Function() isCanceled,
}) async {
  var retry = 3;
  while (true) {
    try {
      Uint8List? data;
      await for (var progress in ImageDownloader.loadComicImageUnwrapped(
          image, sourceKey, comicId, chapter)) {
        if (isCanceled()) {
          throw "Canceled";
        }
        if (progress.imageBytes != null) {
          data = progress.imageBytes;
        }
      }
      if (data == null) {
        throw "Failed to download image".tl;
      }
      var fileType = detectFileType(data);
      var file = saveTo.joinFile("$name${fileType.ext}");
      await file.writeAsBytes(data);
      return file.path;
    } catch (e, st) {
      if (isCanceled()) {
        rethrow;
      }
      Log.error("Download", e.toString(), st);
      retry--;
      if (retry <= 0) {
        rethrow;
      }
      await Future.delayed(Duration(seconds: 3 - retry));
    }
  }
}
