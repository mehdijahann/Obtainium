import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:html/parser.dart';
import 'package:http/http.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class FDroid extends AppSource {
  FDroid() {
    hosts = ['f-droid.org'];
    name = tr('fdroid');
    naiveStandardVersionDetection = true;
    canSearch = true;
    additionalSourceAppSpecificSettingFormItems = [
      [
        GeneratedFormTextField('filterVersionsByRegEx',
            label: tr('filterVersionsByRegEx'),
            required: false,
            additionalValidators: [
              (value) {
                return regExValidator(value);
              }
            ])
      ],
      [
        GeneratedFormSwitch('trySelectingSuggestedVersionCode',
            label: tr('trySelectingSuggestedVersionCode'))
      ],
      [
        GeneratedFormSwitch('autoSelectHighestVersionCode',
            label: tr('autoSelectHighestVersionCode'))
      ],
    ];
  }

  @override
  String sourceSpecificStandardizeURL(String url) {
    RegExp standardUrlRegExB = RegExp(
        '^https?://(www\\.)?${getSourceRegex(hosts)}/+[^/]+/+packages/+[^/]+');
    RegExpMatch? match = standardUrlRegExB.firstMatch(url.toLowerCase());
    if (match != null) {
      url =
          'https://${Uri.parse(match.group(0)!).host}/packages/${Uri.parse(url).pathSegments.last}';
    }
    RegExp standardUrlRegExA =
        RegExp('^https?://(www\\.)?${getSourceRegex(hosts)}/+packages/+[^/]+');
    match = standardUrlRegExA.firstMatch(url.toLowerCase());
    if (match == null) {
      throw InvalidURLError(name);
    }
    return match.group(0)!;
  }

  @override
  Future<String?> tryInferringAppId(String standardUrl,
      {Map<String, dynamic> additionalSettings = const {}}) async {
    return Uri.parse(standardUrl).pathSegments.last;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    String? appId = await tryInferringAppId(standardUrl);
    String host = Uri.parse(standardUrl).host;
    var details = getAPKUrlsFromFDroidPackagesAPIResponse(
        await sourceRequest(
            'https://$host/api/v1/packages/$appId', additionalSettings),
        'https://$host/repo/$appId',
        standardUrl,
        name,
        autoSelectHighestVersionCode:
            additionalSettings['autoSelectHighestVersionCode'] == true,
        trySelectingSuggestedVersionCode:
            additionalSettings['trySelectingSuggestedVersionCode'] == true,
        filterVersionsByRegEx:
            (additionalSettings['filterVersionsByRegEx'] as String?)
                        ?.isNotEmpty ==
                    true
                ? additionalSettings['filterVersionsByRegEx']
                : null);
    if (!hostChanged) {
      try {
        var res = await sourceRequest(
            'https://gitlab.com/fdroid/fdroiddata/-/raw/master/metadata/$appId.yml',
            additionalSettings);
        var lines = res.body.split('\n');
        var authorLines = lines.where((l) => l.startsWith('AuthorName: '));
        if (authorLines.isNotEmpty) {
          details.names.author =
              authorLines.first.split(': ').sublist(1).join(': ');
        }
        var changelogUrls = lines.where((l) => l.startsWith('Changelog: '));
        if (changelogUrls.isNotEmpty) {
          details.changeLog = changelogUrls.first;
          details.changeLog = (await sourceRequest(
                  details.changeLog!
                      .split(': ')
                      .sublist(1)
                      .join(': ')
                      .replaceFirst('/blob/', '/raw/'),
                  additionalSettings))
              .body;
        }
      } catch (e) {
        // Fail silently
      }
      if ((details.changeLog?.length ?? 0) > 2048) {
        details.changeLog = '${details.changeLog!.substring(0, 2048)}...';
      }
    }
    return details;
  }

  @override
  Future<Map<String, List<String>>> search(String query,
      {Map<String, dynamic> querySettings = const {}}) async {
    Response res = await sourceRequest(
        'https://search.${hosts[0]}/?q=${Uri.encodeQueryComponent(query)}', {});
    if (res.statusCode == 200) {
      Map<String, List<String>> urlsWithDescriptions = {};
      parse(res.body).querySelectorAll('.package-header').forEach((e) {
        String? url = e.attributes['href'];
        if (url != null) {
          try {
            standardizeUrl(url);
          } catch (e) {
            url = null;
          }
        }
        if (url != null) {
          urlsWithDescriptions[url] = [
            e.querySelector('.package-name')?.text.trim() ?? '',
            e.querySelector('.package-summary')?.text.trim() ??
                tr('noDescription')
          ];
        }
      });
      return urlsWithDescriptions;
    } else {
      throw getObtainiumHttpError(res);
    }
  }

  APKDetails getAPKUrlsFromFDroidPackagesAPIResponse(
      Response res, String apkUrlPrefix, String standardUrl, String sourceName,
      {bool autoSelectHighestVersionCode = false,
      bool trySelectingSuggestedVersionCode = false,
      String? filterVersionsByRegEx}) {
    if (res.statusCode == 200) {
      var response = jsonDecode(res.body);
      List<dynamic> releases = response['packages'] ?? [];
      if (releases.isEmpty) {
        throw NoReleasesError();
      }
      String? version;
      Iterable<dynamic> releaseChoices = [];
      // Grab the versionCode suggested if the user chose to do that
      // Only do so at this stage if the user has no release filter
      if (trySelectingSuggestedVersionCode &&
          response['suggestedVersionCode'] != null &&
          filterVersionsByRegEx == null) {
        var suggestedReleases = releases.where((element) =>
            element['versionCode'] == response['suggestedVersionCode']);
        if (suggestedReleases.isNotEmpty) {
          releaseChoices = suggestedReleases;
          version = suggestedReleases.first['versionName'];
        }
      }
      // Apply the release filter if any
      if (filterVersionsByRegEx?.isNotEmpty == true) {
        version = null;
        releaseChoices = [];
        for (var i = 0; i < releases.length; i++) {
          if (RegExp(filterVersionsByRegEx!)
              .hasMatch(releases[i]['versionName'])) {
            version = releases[i]['versionName'];
          }
        }
        if (version == null) {
          throw NoVersionError();
        }
      }
      // Default to the highest version
      version ??= releases[0]['versionName'];
      if (version == null) {
        throw NoVersionError();
      }
      // If a suggested release was not already picked, pick all those with the selected version
      if (releaseChoices.isEmpty) {
        releaseChoices =
            releases.where((element) => element['versionName'] == version);
      }
      // For the remaining releases, use the toggles to auto-select one if possible
      if (releaseChoices.length > 1) {
        if (autoSelectHighestVersionCode) {
          releaseChoices = [releaseChoices.first];
        } else if (trySelectingSuggestedVersionCode &&
            response['suggestedVersionCode'] != null) {
          var suggestedReleases = releaseChoices.where((element) =>
              element['versionCode'] == response['suggestedVersionCode']);
          if (suggestedReleases.isNotEmpty) {
            releaseChoices = suggestedReleases;
          }
        }
      }
      if (releaseChoices.isEmpty) {
        throw NoReleasesError();
      }
      List<String> apkUrls = releaseChoices
          .map((e) => '${apkUrlPrefix}_${e['versionCode']}.apk')
          .toList();
      return APKDetails(version, getApkUrlsFromUrls(apkUrls.toSet().toList()),
          AppNames(sourceName, Uri.parse(standardUrl).pathSegments.last));
    } else {
      throw getObtainiumHttpError(res);
    }
  }
}
