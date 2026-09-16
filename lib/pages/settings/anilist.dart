part of 'settings_page.dart';

class _AniListSettings extends StatefulWidget {
  const _AniListSettings();

  @override
  State<_AniListSettings> createState() => _AniListSettingsState();
}

class _AniListSettingsState extends State<_AniListSettings> {
  /// AniList user name of the stored token. Null while loading or when the
  /// token is missing or invalid.
  String? userName;

  bool isLoading = false;

  String? error;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  void _loadUser() async {
    if (!AniListManager().isLoggedIn) {
      return;
    }
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      var name = await AniListManager().verifyToken();
      if (!mounted) return;
      setState(() {
        userName = name;
        isLoading = false;
      });
    } catch (e) {
      Log.error("AniList", "Failed to verify token: $e");
      if (!mounted) return;
      setState(() {
        userName = null;
        isLoading = false;
        error = e is AniListException
            ? e.message
            : "Failed to connect to AniList".tl;
      });
    }
  }

  void _connect() async {
    launchUrlString(aniListAuthorizeUrl);
    await showInputDialog(
      context: context,
      title: "Connect AniList".tl,
      hintText: "Paste the access token here".tl,
      onConfirm: (value) async {
        var token = value.trim();
        if (token.isEmpty) {
          return "The token must not be empty".tl;
        }
        var previous = AniListManager().token;
        AniListManager().token = token;
        try {
          var name = await AniListManager().verifyToken();
          if (mounted) {
            setState(() {
              userName = name;
              error = null;
            });
          }
          return null;
        } catch (e) {
          Log.error("AniList", "Failed to verify token: $e");
          AniListManager().token = previous;
          return e is AniListException
              ? e.message
              : "Failed to connect to AniList".tl;
        }
      },
    );
  }

  void _disconnect() {
    AniListManager().token = null;
    setState(() {
      userName = null;
      error = null;
    });
    context.showMessage(message: "AniList account disconnected".tl);
  }

  @override
  Widget build(BuildContext context) {
    var isLoggedIn = AniListManager().isLoggedIn;
    String subtitle;
    if (!isLoggedIn) {
      subtitle = "Not connected".tl;
    } else if (isLoading) {
      subtitle = "Checking the account...".tl;
    } else if (error != null) {
      subtitle = error!;
    } else if (userName != null) {
      subtitle = "Connected as @name".tlParams({"name": userName!});
    } else {
      subtitle = "Connected".tl;
    }

    return Column(
      children: [
        ListTile(
          title: Text("Account".tl),
          subtitle: Text(subtitle),
          trailing: Button.normal(
            onPressed: isLoggedIn ? _disconnect : _connect,
            child: Text(isLoggedIn ? "Disconnect".tl : "Connect".tl),
          ).fixHeight(28),
        ),
        if (isLoggedIn && error != null)
          ListTile(
            title: Text("Reconnect".tl),
            subtitle: Text(
              "The token may be expired. Connect the account again.".tl,
            ),
            trailing: Button.normal(
              onPressed: _connect,
              child: Text("Connect".tl),
            ).fixHeight(28),
          ),
        ListTile(
          title: Text("Tracked comics".tl),
          subtitle: Text(
            "@count comics are linked to AniList".tlParams({
              "count": AniListManager().getAll().length,
            }),
          ),
        ),
      ],
    );
  }
}
