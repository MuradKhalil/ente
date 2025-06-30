import "dart:math";

import "package:collection/collection.dart";
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logging/logging.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/models/file/file.dart';
import "package:photos/models/search/generic_search_result.dart";
import "package:photos/models/search/search_constants.dart";
import "package:photos/models/search/search_types.dart";
import 'package:photos/service_locator.dart';
import 'package:photos/services/home_widget_service.dart';
import 'package:photos/services/machine_learning/face_ml/person/person_service.dart';
import 'package:photos/services/search_service.dart';
import 'package:photos/services/sync/local_sync_service.dart';
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/ui/viewer/people/people_page.dart";
import 'package:photos/utils/navigation_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

class PeopleHomeWidgetService {
  // Constants
  static const String SELECTED_PEOPLE_KEY = "selectedPeopleHW";
  static const String PEOPLE_LAST_HASH_KEY = "peopleLastHash";
  static const String ANDROID_CLASS_NAME = "EntePeopleWidgetProvider";
  static const String IOS_CLASS_NAME = "EntePeopleWidget";
  static const String PEOPLE_STATUS_KEY = "peopleStatusKey.widget";
  static const String PEOPLE_CHANGED_KEY = "peopleChanged.widget";
  static const int MAX_PEOPLE_LIMIT = 50;

  // Singleton pattern
  static final PeopleHomeWidgetService instance =
      PeopleHomeWidgetService._privateConstructor();
  PeopleHomeWidgetService._privateConstructor();

  // Properties
  final Logger _logger = Logger((PeopleHomeWidgetService).toString());
  late final SharedPreferences _prefs;
  final peopleChangedLock = Lock();

  // Initialization
  void init(SharedPreferences prefs) {
    _prefs = prefs;
  }

  // Public methods
  List<String>? getSelectedPeople() {
    return _prefs.getStringList(SELECTED_PEOPLE_KEY);
  }

  Future<void> setSelectedPeople(List<String> selectedPeople) async {
    await _prefs.setStringList(SELECTED_PEOPLE_KEY, selectedPeople);

    _logger.info("People selection changed, updating widget");
    await checkPeopleChanged();
  }

  String? getPeopleLastHash() {
    return _prefs.getString(PEOPLE_LAST_HASH_KEY);
  }

  Future<void> setPeopleLastHash(String hash) async {
    await _prefs.setString(PEOPLE_LAST_HASH_KEY, hash);
  }

  Future<void> initPeopleHomeWidget() async {
    await HomeWidgetService.instance.computeLock.synchronized(() async {
      if (await _hasAnyBlockers()) {
        await clearWidget();
        return;
      }

      final bool forceFetchNewPeople = await _shouldUpdateWidgetCache();

      if (forceFetchNewPeople) {
        _logger.info("Initializing people widget: updating people cache");
        await _updatePeopleWidgetCache();
        await updatePeopleChanged(false);
      } else {
        _logger.info("Initializing people widget: syncing existing people");
        await _refreshPeopleWidget();
      }
    });
  }

  Future<void> clearWidget() async {
    if (getPeopleStatus() == WidgetStatus.syncedEmpty) {
      _logger.info("Widget already empty, nothing to clear");
      return;
    }

    await setPeopleLastHash("");
    await updatePeopleStatus(WidgetStatus.syncedEmpty);
    await _refreshWidget(message: "PeopleHomeWidget cleared & updated");
  }

  bool getPeopleChanged() {
    return _prefs.getBool(PEOPLE_CHANGED_KEY) ?? false;
  }

  Future<void> updatePeopleChanged(bool value) async {
    _logger.info("Updating people changed flag to $value");
    await _prefs.setBool(PEOPLE_CHANGED_KEY, value);
  }

  WidgetStatus getPeopleStatus() {
    return WidgetStatus.values.firstWhereOrNull(
          (v) => v.index == (_prefs.getInt(PEOPLE_STATUS_KEY) ?? 0),
        ) ??
        WidgetStatus.notSynced;
  }

  Future<void> updatePeopleStatus(WidgetStatus value) async {
    await _prefs.setInt(PEOPLE_STATUS_KEY, value.index);
  }

  Future<void> checkPendingPeopleSync() async {
    if (await _hasAnyBlockers()) {
      await clearWidget();
      return;
    }

    if (await _shouldUpdateWidgetCache()) {
      await initPeopleHomeWidget();
    }
  }

  Future<void> checkPeopleChanged() async {
    final havePeopleChanged = await peopleChangedLock.synchronized(() async {
      final peopleIds = await _getEffectiveSelectedPeopleIds();
      final currentHash = await _calculateHash(peopleIds);
      final lastHash = getPeopleLastHash();

      if (lastHash != null && currentHash == lastHash) {
        return false;
      }

      return true;
    });

    await updatePeopleChanged(havePeopleChanged);
    if (!havePeopleChanged) {
      _logger.info("No changes detected in people, skipping update");
      return;
    }
    await initPeopleHomeWidget();
  }

  Future<int> countHomeWidgets() async {
    return await HomeWidgetService.instance.countHomeWidgets(
      ANDROID_CLASS_NAME,
      IOS_CLASS_NAME,
    );
  }

  Future<void> onLaunchFromWidget(
    int fileId,
    String personId,
    BuildContext context,
  ) async {
    final file = await FilesDB.instance.getFile(fileId);
    if (file == null) {
      _logger.warning("Cannot launch widget: file with ID $fileId not found");
      return;
    }

    final person = await PersonService.instance.getPerson(personId);
    if (person == null) {
      _logger
          .warning("Cannot launch widget: person with ID $personId not found");
      return;
    }

    routeToPage(
      context,
      PeoplePage(
        person: person,
        searchResult: null,
      ),
      forceCustomPageRoute: true,
    ).ignore();

    final clusterFiles =
        await SearchService.instance.getClusterFilesForPersonID(
      personId,
    );
    final files = clusterFiles.entries.expand((e) => e.value).toList();

    routeToPage(
      context,
      DetailPage(
        DetailPageConfiguration(
          files,
          files.indexOf(file),
          "peoplewidget",
        ),
      ),
      forceCustomPageRoute: true,
    ).ignore();
    await _refreshPeopleWidget();
  }

  Future<String> _calculateHash(List<String> peopleIds) async {
    return await entityService.getHashForIds(peopleIds);
  }

  Future<bool> _hasAnyBlockers() async {
    if (await countHomeWidgets() == 0) {
      return true;
    }

    // Check if first import is completed
    final hasCompletedFirstImport =
        LocalSyncService.instance.hasCompletedFirstImport();
    if (!hasCompletedFirstImport) {
      return true;
    }

    // Check ML consent
    if (!flagService.hasGrantedMLConsent) {
      return true;
    }

    // Check if selected people or hash exist
    final peopleIds = await _getEffectiveSelectedPeopleIds();
    final hash = await _calculateHash(peopleIds);

    final noSelectionOrHashEmpty = peopleIds.isEmpty || hash.isEmpty;
    if (noSelectionOrHashEmpty) {
      return true;
    }

    return false;
  }

  Future<void> _refreshPeopleWidget() async {
    // only refresh if widget was synced without issues
    if (getPeopleStatus() == WidgetStatus.syncedAll) return;
    await _refreshWidget(message: "Refreshing from existing people set");
  }

  Future<bool> _shouldUpdateWidgetCache() async {
    // Update widget cache when people were changed
    if (getPeopleChanged() == true) {
      return true;
    }

    // update widget cache if
    // - people not synced
    // - people synced partially but now home widget is present
    final peopleStatus = getPeopleStatus();
    return peopleStatus == WidgetStatus.notSynced ||
        peopleStatus == WidgetStatus.syncedPartially &&
            await countHomeWidgets() > 0;
  }

  Future<List<String>> _getEffectiveSelectedPeopleIds() async {
    var peopleIds = getSelectedPeople();

    // Select first two named people by default
    if (peopleIds == null || peopleIds.isEmpty) {
      final searchFilter = await SectionType.face.getData(null).then(
            (value) => (value as List<GenericSearchResult>).where(
              (element) => (element.params[kPersonParamID] as String?) != null,
            ),
          );

      if (searchFilter.isNotEmpty) {
        peopleIds = searchFilter
            .take(2)
            .map((e) => e.params[kPersonParamID] as String)
            .toList();
      } else {
        _logger.warning("No selected people found");
      }
    }

    return peopleIds ?? [];
  }

  Future<Map<String, (String, Iterable<EnteFile>)>> _getPeople(
    List<String> personIds,
  ) async {
    final Map<String, (String, Iterable<EnteFile>)> peopleFiles = {};
    final persons = await PersonService.instance.getCertainPersons(personIds);
    for (final person in persons) {
      final clusterFiles = await SearchService.instance
          .getClusterFilesForPersonID(person.remoteID);
      final files = clusterFiles.entries.expand((e) => e.value).toList();
      if (files.isEmpty) {
        _logger.warning("No files found for person: ${person.data.name}");
        continue;
      }
      peopleFiles[person.remoteID] = (person.data.name, files);
    }

    return peopleFiles;
  }

  Future<void> _refreshWidget({String? message}) async {
    await HomeWidgetService.instance.updateWidget(
      androidClass: ANDROID_CLASS_NAME,
      iOSClass: IOS_CLASS_NAME,
    );

    if (flagService.internalUser) {
      await Fluttertoast.showToast(
        msg: "[i][ppl] ${message ?? "PeopleHomeWidget updated"}",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        timeInSecForIosWeb: 1,
        backgroundColor: Colors.black,
        textColor: Colors.white,
        fontSize: 16.0,
      );
    }

    _logger.info("Home Widget updated: ${message ?? "standard update"}");
  }

  Future<void> _updatePeopleWidgetCache() async {
    final peopleIds = await _getEffectiveSelectedPeopleIds();
    // TODO: Add logic to directly get random people files from database
    final peopleWithFiles = await _getPeople(peopleIds);

    if (peopleWithFiles.isEmpty) {
      _logger.warning("No files found for any people, clearing widget");
      await clearWidget();
      return;
    }

    const limit = MAX_PEOPLE_LIMIT;
    const maxAttempts = limit * 10;

    int renderedCount = 0;
    int attemptsCount = 0;

    await updatePeopleStatus(WidgetStatus.notSynced);

    final peopleWithFilesLength = peopleWithFiles.length;
    final peopleWithFilesEntries = peopleWithFiles.entries.toList();
    final random = Random();

    while (renderedCount < limit && attemptsCount < maxAttempts) {
      final randomEntry =
          peopleWithFilesEntries[random.nextInt(peopleWithFilesLength)];

      if (randomEntry.value.$2.isEmpty) continue;

      final randomPersonFile = randomEntry.value.$2.elementAt(
        random.nextInt(randomEntry.value.$2.length),
      );
      final personId = randomEntry.key;
      final personName = randomEntry.value.$1;

      final renderResult = await HomeWidgetService.instance
          .renderFile(
        randomPersonFile,
        "people_widget_$renderedCount",
        personName,
        personId,
      )
          .catchError((e, stackTrace) {
        _logger.severe("Error rendering widget", e, stackTrace);
        return null;
      });

      if (renderResult != null) {
        // Check for blockers again before continuing
        if (await _hasAnyBlockers()) {
          return;
        }

        // Show update toast after first item is rendered
        if (renderedCount == 1) {
          await _refreshWidget(
            message: "First person fetched, updating widget",
          );
          await updatePeopleStatus(WidgetStatus.syncedPartially);
        }

        renderedCount++;
      }

      attemptsCount++;
    }

    if (attemptsCount >= maxAttempts) {
      _logger.warning(
        "Hit max attempts $maxAttempts. Only rendered $renderedCount of limit $limit.",
      );
    }

    if (renderedCount == 0) {
      return;
    }

    await updatePeopleStatus(WidgetStatus.syncedAll);

    final hash = await _calculateHash(peopleIds);
    await setPeopleLastHash(hash);

    await _refreshWidget(
      message: "Switched to next people set, total: $renderedCount",
    );
  }
}
