import 'package:html/parser.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/source_provider.dart';

class GitLab implements AppSource {
  @override
  late String host = 'gitlab.com';

  @override
  String standardizeURL(String url) {
    RegExp standardUrlRegEx = RegExp('^https?://$host/[^/]+/[^/]+');
    RegExpMatch? match = standardUrlRegEx.firstMatch(url.toLowerCase());
    if (match == null) {
      throw notValidURL;
    }
    return url.substring(0, match.end);
  }

  @override
  Future<APKDetails> getLatestAPKDetails(String standardUrl) async {
    Response res = await get(Uri.parse('$standardUrl/-/tags?format=atom'));
    if (res.statusCode == 200) {
      var standardUri = Uri.parse(standardUrl);
      var parsedHtml = parse(res.body);
      var entry = parsedHtml.querySelector('entry');
      var entryContent =
          parse(parseFragment(entry?.querySelector('content')!.innerHtml).text);
      var apkUrlList = [
        ...getLinksFromParsedHTML(
            entryContent,
            RegExp(
                '^${escapeRegEx(standardUri.path)}/uploads/[^/]+/[^/]+\\.apk\$',
                caseSensitive: false),
            standardUri.origin),
        // GitLab releases may contain links to externally hosted APKs
        ...getLinksFromParsedHTML(entryContent,
                RegExp('/[^/]+\\.apk\$', caseSensitive: false), '')
            .where((element) => Uri.parse(element).host != '')
            .toList()
      ];
      if (apkUrlList.isEmpty) {
        throw noAPKFound;
      }

      var entryId = entry?.querySelector('id')?.innerHtml;
      var version =
          entryId == null ? null : Uri.parse(entryId).pathSegments.last;
      if (version == null) {
        throw couldNotFindLatestVersion;
      }
      return APKDetails(version, apkUrlList);
    } else {
      throw couldNotFindReleases;
    }
  }

  @override
  AppNames getAppNames(String standardUrl) {
    // Same as GitHub
    return GitHub().getAppNames(standardUrl);
  }
}
