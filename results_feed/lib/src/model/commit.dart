// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:firebase/firestore.dart' as firestore;

import '../services/filter_service.dart';
import 'comment.dart';

class IntRangeIterator implements Iterator<int> {
  int current;
  int end;

  IntRangeIterator(int start, this.end) {
    current = start - 1;
  }

  bool moveNext() {
    current++;
    if (current > end) current = null;
    return current != null;
  }
}

class IntRange with IterableMixin<int> implements Comparable {
  IntRange(this.start, this.end);

  final int start;
  final int end;

  bool operator ==(other) =>
      other is IntRange && other.start == start && other.end == end;

  int get hashCode => start + end * 40927 % 63703;

  Iterator<int> get iterator => IntRangeIterator(start, end);

  bool contains(Object i) => i as int >= start && i as int <= end;

  int get length => end - start + 1;

  int compareTo(dynamic other) {
    IntRange o = other; // Throw TypeError if not an IntRange
    return end == o.end ? start.compareTo(o.start) : end.compareTo(o.end);
  }

  String toString() => "IntRange($start, $end)";
}

class Commit implements Comparable {
  final String hash;
  final String author;
  final String title;
  final DateTime created;
  final int index;

  Commit(this.hash, this.author, this.title, this.created, this.index);

  Commit.fromDocument(firestore.DocumentSnapshot document)
      : hash = document.id,
        author = document.get('author'),
        title = document.get('title'),
        created = document.get('created'),
        index = document.get('index');

  /// Sort in reverse index order.
  int compareTo(other) => (other as Commit).index.compareTo(index);

  String toString() => "$index $hash $author $created $title";
}

class ChangeGroup implements Comparable {
  final IntRange range;
  List<Commit> commits;
  List<Comment> comments;
  final Changes changes;
  final Changes latestChanges;
  Changes _filteredChanges;
  Filter _filter = Filter.defaultFilter;

  ChangeGroup(
      IntRange this.range,
      Map<int, Commit> allCommits,
      List<Comment> this.comments,
      Iterable<Change> changeList,
      Iterable<Change> liveChangeList)
      : changes = Changes(changeList),
        latestChanges = Changes(liveChangeList) {
    commits = [
      if (range != null)
        for (int i in range) if (allCommits[i] != null) allCommits[i]
    ]..sort();
  }

  /// Sort in reverse chronological order.
  int compareTo(other) => (other as ChangeGroup).range.compareTo(range);

  bool show(Filter filter) =>
      filter.showAllCommits || filteredChanges(filter).isNotEmpty;

  Changes shownChanges(Filter filter) =>
      filter.showLatestFailures ? latestChanges : changes;

  Changes filteredChanges(Filter filter) =>
      (filter == _filter) ? _filteredChanges : computeFilteredChanges(filter);

  Changes computeFilteredChanges(filter) {
    _filteredChanges = shownChanges(filter).filtered(filter);
    _filter = filter;
    return _filteredChanges;
  }
}

/// A list of configurations affected by a result change.
/// The list is canonicalized, and configurations are grouped into
/// summaries of similar configurations.
class Configurations {
  static final _instances = <String, Configurations>{};
  List<String> configurations;
  String text;
  Map<String, List<String>> summaries;

  Configurations._(List<dynamic> configurations)
      : configurations = List<String>.from(configurations),
        text = configurations.join(),
        summaries = _summarize(configurations);

  factory Configurations(List configs) {
    if (configs.isEmpty) return null;
    configs.sort();
    return _instances.putIfAbsent(
        configs.join(' '), () => Configurations._(configs.toList()));
  }

  static Map<String, List<String>> _summarize(List<dynamic> configurations) {
    final groups = <String, List<String>>{};
    for (final String configuration in configurations) {
      groups
          .putIfAbsent(configuration.split('-').first, () => <String>[])
          .add(configuration);
    }
    // Sorts the values as a side effect, while changing their keys.
    return SplayTreeMap.fromIterable(groups.values,
        key: (list) => (list..sort).length == 1
            ? list.first
            : list.first.split('-').first + '...');
  }

  bool show(Filter filter) =>
      filter.allGroups ||
      configurations.any((configuration) =>
          filter.configurationGroups.any(configuration.startsWith));
}

class Change implements Comparable {
  Change._(
      this.id,
      this.name,
      this.configurations,
      this.result,
      this.previousResult,
      this.expected,
      this.blamelistStartIndex,
      this.blamelistEndIndex,
      this.pinnedIndex,
      this.trivialBlamelist)
      : changesText = '$previousResult -> $result (expected $expected)',
        configurationsText = configurations.text;

  Change.fromDocument(firestore.DocumentSnapshot document)
      : this._(
            document.id,
            document.get('name'),
            Configurations(document.get('configurations')),
            document.get('result'),
            document.get('previous_result'),
            document.get('expected'),
            document.get('blamelist_start_index'),
            document.get('blamelist_end_index'),
            document.get('pinned_index'),
            document.get('trivial_blamelist'));

  final String id;
  final String name;
  final Configurations configurations;
  final String result;
  final String previousResult;
  final String expected;
  final int blamelistStartIndex;
  final int blamelistEndIndex;
  int pinnedIndex;
  bool trivialBlamelist;
  final String configurationsText;
  final String changesText;

  Change copy({List<String> newConfigurations}) => Change._(
      id,
      name,
      newConfigurations == null
          ? configurations
          : Configurations(newConfigurations),
      result,
      previousResult,
      expected,
      blamelistStartIndex,
      blamelistEndIndex,
      pinnedIndex,
      trivialBlamelist);

  int compareTo(Object other) => name.compareTo((other as Change).name);

  String get resultStyle => result == expected ? 'success' : 'failure';
}

class Changes with IterableMixin<List<List<Change>>> {
  final List<List<List<Change>>> changes;

  Changes(Iterable<Change> newChanges) : this.grouped(group(newChanges));

  Changes.grouped(List<List<List<Change>>> this.changes);

  get iterator => changes.iterator;

  /// The changes, grouped first by Configurations object, then by
  /// changesText (the change in the results). Should not be modified
  /// after it is created by this call.
  static List<List<List<Change>>> group(Iterable<Change> newChanges) {
    final map = SplayTreeMap<String, SplayTreeMap<String, List<Change>>>();
    for (final change in newChanges) {
      map
          .putIfAbsent(change.configurations.text,
              () => SplayTreeMap<String, List<Change>>())
          .putIfAbsent(change.changesText, () => List<Change>())
          .add(change);
    }
    return [
      for (final configuration in map.keys)
        [
          for (final change in map[configuration].keys)
            map[configuration][change]..sort()
        ]
    ];
  }

  static bool empty(x, f) => x.isEmpty;

  Changes filtered(Filter filter) {
    final newChanges =
        applyFilter<List<List<Change>>>(configurationFilter, changes, filter);
    return newChanges == changes ? this : Changes.grouped(newChanges);
  }

  /// Process a list by applying elementFilter to its elements, then throw
  /// out empty or otherwise filtered elements with the emptyTest filter.
  /// If no elements are modified or dropped, returns the input list object.
  static applyFilter<T>(
      T elementFilter(T t, Filter f), List<T> list, Filter filter,
      [bool emptyTest(dynamic, Filter) = empty]) {
    final newList = <T>[];
    bool changed = false;
    for (final element in list) {
      final T newElement = elementFilter(element, filter);
      changed = changed || newElement != element;
      if (!emptyTest(newElement, filter)) newList.add(newElement);
    }
    return changed ? newList : list;
  }

  List<List<Change>> configurationFilter(
      List<List<Change>> list, Filter filter) {
    if (list.first.first.configurations.show(filter)) {
      return applyFilter<List<Change>>(resultFilter, list, filter);
    }
    return [];
  }

  List<Change> resultFilter(List<Change> list, Filter filter) {
    if (filter.showLatestFailures && list.first.resultStyle != 'failure') {
      return [];
    }
    return applyFilter<Change>((c, f) => c, list, filter,
        (change, filter) => filter.showUnapprovedOnly && !change.approved);
  }
}