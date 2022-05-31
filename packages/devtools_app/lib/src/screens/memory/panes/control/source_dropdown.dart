// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

import '../../../../analytics/analytics.dart' as ga;
import '../../../../analytics/constants.dart' as analytics_constants;
import '../../../../shared/common_widgets.dart';
import '../../memory_controller.dart';
import 'constants.dart';

class SourceDropdownMenuItem<T> extends DropdownMenuItem<T> {
  const SourceDropdownMenuItem({T? value, required Widget child})
      : super(value: value, child: child);
}

class MemorySourceDropdown extends StatefulWidget {
  const MemorySourceDropdown({Key? key}) : super(key: key);

  @override
  State<MemorySourceDropdown> createState() => _MemorySourceDropdownState();
}

class _MemorySourceDropdownState extends State<MemorySourceDropdown>
    with MemoryControllerMixin {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    initMemoryController();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final files = memoryController.memoryLog.offlineFiles();

    // Can we display dropdowns in verbose mode?
    final isVerbose =
        memoryController.memorySourcePrefix == memorySourceMenuItemPrefix;

    // First item is 'Live Feed', then followed by memory log filenames.
    files.insert(0, MemoryController.liveFeed);

    final allMemorySources = files.map<DropdownMenuItem<String>>((
      String value,
    ) {
      // If narrow width compact the displayed name (remove prefix 'memory_log_').
      final displayValue =
          (!isVerbose && value.startsWith(MemoryController.logFilenamePrefix))
              ? value.substring(MemoryController.logFilenamePrefix.length)
              : value;
      return SourceDropdownMenuItem<String>(
        value: value,
        child: Text(
          '${memoryController.memorySourcePrefix}$displayValue',
          key: sourcesKey,
        ),
      );
    }).toList();

    return RoundedDropDownButton<String>(
      key: sourcesDropdownKey,
      isDense: true,
      style: textTheme.bodyText2,
      value: memoryController.memorySource,
      onChanged: (String? newValue) {
        setState(() {
          ga.select(
            analytics_constants.memory,
            analytics_constants.sourcesDropDown,
          );
          memoryController.memorySource = newValue!;
        });
      },
      items: allMemorySources,
    );
  }
}