part of 'comic_page.dart';

/// Side panel used to link a comic to an AniList entry, or to inspect and
/// remove an existing link.
class _AniListPanel extends StatefulWidget {
  const _AniListPanel({
    required this.sourceKey,
    required this.comicId,
    required this.initialSearch,
    required this.onChanged,
  });

  final String sourceKey;

  final String comicId;

  /// Text the search box starts with, normally the comic title.
  final String initialSearch;

  final void Function() onChanged;

  @override
  State<_AniListPanel> createState() => _AniListPanelState();
}

class _AniListPanelState extends State<_AniListPanel> {
  late final TextEditingController controller;

  AniListLink? link;

  List<AniListMedia> results = const [];

  bool isLoading = false;

  String? error;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialSearch);
    link = AniListManager().find(widget.sourceKey, widget.comicId);
    search();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void search() async {
    var keyword = controller.text.trim();
    if (keyword.isEmpty) {
      return;
    }
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      var res = await AniListManager().search(keyword);
      if (!mounted) return;
      setState(() {
        results = res;
        isLoading = false;
      });
    } catch (e, s) {
      Log.error("AniList", "Search failed: $e", s);
      if (!mounted) return;
      setState(() {
        isLoading = false;
        error = e.toString();
      });
    }
  }

  void linkTo(AniListMedia media) {
    AniListManager().link(AniListLink(
      sourceKey: widget.sourceKey,
      comicId: widget.comicId,
      mediaId: media.id,
      title: media.title,
      totalChapters: media.chapters,
      createdAt: DateTime.now(),
    ));
    widget.onChanged();
    context.pop();
    App.rootContext.showMessage(
      message: "Linked to @name".tlParams({"name": media.title}),
    );
  }

  void unlink() {
    AniListManager().unlink(widget.sourceKey, widget.comicId);
    widget.onChanged();
    context.pop();
    App.rootContext.showMessage(message: "Tracking removed".tl);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("AniList".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (link != null)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(link!.title),
              subtitle: Text(
                "Synced progress: @progress".tlParams({
                  "progress": link!.totalChapters == null
                      ? "${link!.lastSyncedProgress}"
                      : "${link!.lastSyncedProgress}/${link!.totalChapters}",
                }),
              ),
              trailing: Button.normal(
                onPressed: unlink,
                child: Text("Unlink".tl),
              ).fixHeight(28),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "Search on AniList".tl,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => search(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: search,
              ),
            ],
          ).paddingHorizontal(16).paddingVertical(8),
          Expanded(child: buildResults()),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }

  Widget buildResults() {
    if (isLoading) {
      return const ListLoadingIndicator().toCenter();
    }
    if (error != null) {
      return Text(error!).toCenter().paddingHorizontal(16);
    }
    if (results.isEmpty) {
      return Text("No results found".tl).toCenter();
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: results.length,
      itemBuilder: (context, i) {
        var media = results[i];
        return ListTile(
          leading: media.cover == null
              ? null
              : SizedBox(
                  width: 42,
                  child: Image.network(media.cover!, fit: BoxFit.cover),
                ),
          title: Text(media.title),
          subtitle: Text(_describe(media)),
          selected: media.id == link?.mediaId,
          onTap: () => linkTo(media),
        );
      },
    );
  }

  String _describe(AniListMedia media) {
    var parts = <String>[];
    if (media.chapters != null) {
      parts.add("@count chapters".tlParams({"count": media.chapters!}));
    }
    if (media.status != null) {
      parts.add(media.status!);
    }
    return parts.join(" - ");
  }
}
