// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:devtools_app_shared/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../shared/analytics/analytics.dart' as ga;
import '../../shared/analytics/constants.dart' as gac;
import '../../shared/config_specific/copy_to_clipboard/copy_to_clipboard.dart';
import '../../shared/framework/screen.dart';
import '../../shared/globals.dart';
import '../../shared/http/curl_command.dart';
import '../../shared/http/http_request_data.dart';
import '../../shared/primitives/utils.dart';
import '../../shared/table/table.dart';
import '../../shared/table/table_data.dart';
import '../../shared/ui/common_widgets.dart';
import '../../shared/ui/filter.dart';
import '../../shared/ui/search.dart';
import '../../shared/ui/utils.dart';
import '../../shared/utils/utils.dart';
import 'network_controller.dart';
import 'network_model.dart';
import 'network_request_inspector.dart';

class NetworkScreen extends Screen {
  NetworkScreen() : super.fromMetaData(ScreenMetaData.network);

  static final id = ScreenMetaData.network.id;

  @override
  String get docPageId => screenId;

  @override
  Widget buildScreenBody(BuildContext context) => const NetworkScreenBody();

  @override
  Widget buildStatus(BuildContext context) {
    final networkController = Provider.of<NetworkController>(context);
    final color = Theme.of(context).colorScheme.onPrimary;
    return MultiValueListenableBuilder(
      listenables: [networkController.requests, networkController.filteredData],
      builder: (context, values, child) {
        final networkRequests = values.first as List<NetworkRequest>;
        final filteredRequests = values.second as List<NetworkRequest>;
        final filteredCount = filteredRequests.length;
        final totalCount = networkRequests.length;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Showing ${nf.format(filteredCount)} of '
              '${nf.format(totalCount)} '
              '${pluralize('request', totalCount)}',
            ),
            const SizedBox(width: denseSpacing),
            child!,
          ],
        );
      },
      child: ValueListenableBuilder<bool>(
        valueListenable: networkController.recordingNotifier,
        builder: (context, recording, _) {
          return SizedBox(
            width: smallProgressSize,
            height: smallProgressSize,
            child:
                recording
                    ? SmallCircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    )
                    : const SizedBox(),
          );
        },
      ),
    );
  }
}

class NetworkScreenBody extends StatefulWidget {
  const NetworkScreenBody({super.key});

  @override
  State<StatefulWidget> createState() => _NetworkScreenBodyState();
}

class _NetworkScreenBodyState extends State<NetworkScreenBody>
    with
        AutoDisposeMixin,
        ProvidedControllerMixin<NetworkController, NetworkScreenBody> {
  @override
  void initState() {
    super.initState();
    ga.screen(NetworkScreen.id);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initController()) return;
    unawaited(controller.startRecording());

    cancelListeners();

    addAutoDisposeListener(
      serviceConnection.serviceManager.isolateManager.mainIsolate,
      () {
        if (serviceConnection.serviceManager.isolateManager.mainIsolate.value !=
            null) {
          unawaited(controller.startRecording());
        }
      },
    );
  }

  @override
  void dispose() {
    // TODO(kenz): this won't work well if we eventually have multiple clients
    // that want to listen to network data.
    super.dispose();
    unawaited(controller.stopRecording());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _NetworkProfilerControls(controller: controller),
        const SizedBox(height: intermediateSpacing),
        Expanded(child: _NetworkProfilerBody(controller: controller)),
      ],
    );
  }
}

/// The row of controls that control the Network profiler (e.g., record, pause,
/// clear, search, filter, etc.).
class _NetworkProfilerControls extends StatefulWidget {
  const _NetworkProfilerControls({required this.controller});

  static const _includeTextWidth = 810.0;

  final NetworkController controller;

  @override
  State<_NetworkProfilerControls> createState() =>
      _NetworkProfilerControlsState();
}

class _NetworkProfilerControlsState extends State<_NetworkProfilerControls>
    with AutoDisposeMixin {
  bool _recording = false;

  @override
  void initState() {
    super.initState();

    _recording = widget.controller.recordingNotifier.value;
    addAutoDisposeListener(widget.controller.recordingNotifier, () {
      setState(() {
        _recording = widget.controller.recordingNotifier.value;
      });
    });

    addAutoDisposeListener(widget.controller.filteredData);
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = ScreenSize(context).width;
    final hasRequests = widget.controller.filteredData.value.isNotEmpty;
    return Row(
      children: [
        StartStopRecordingButton(
          recording: _recording,
          onPressed:
              () async => await widget.controller.togglePolling(!_recording),
          tooltipOverride:
              _recording
                  ? 'Stop recording network traffic'
                  : 'Resume recording network traffic',
          minScreenWidthForTextBeforeScaling: double.infinity,
          gaScreen: gac.network,
          gaSelection: _recording ? gac.pause : gac.resume,
        ),
        const SizedBox(width: denseSpacing),
        ClearButton(
          minScreenWidthForTextBeforeScaling:
              _NetworkProfilerControls._includeTextWidth,
          gaScreen: gac.network,
          gaSelection: gac.clear,
          onPressed: widget.controller.clear,
        ),
        const SizedBox(width: defaultSpacing),
        DownloadButton(
          tooltip: 'Download as .har file',
          minScreenWidthForTextBeforeScaling:
              _NetworkProfilerControls._includeTextWidth,
          onPressed: widget.controller.exportAsHarFile,
          gaScreen: gac.network,
          gaSelection: gac.NetworkEvent.downloadAsHar.name,
        ),
        const SizedBox(width: defaultSpacing),
        // TODO(kenz): fix focus issue when state is refreshed
        Expanded(
          child: SearchField<NetworkController>(
            searchController: widget.controller,
            searchFieldEnabled: hasRequests,
            searchFieldWidth:
                screenWidth <= MediaSize.xs
                    ? defaultSearchFieldWidth
                    : wideSearchFieldWidth,
          ),
        ),
        const SizedBox(width: denseSpacing),
        Expanded(
          child: StandaloneFilterField<NetworkRequest>(
            controller: widget.controller,
            filteredItem: 'request',
          ),
        ),
      ],
    );
  }
}

class _NetworkProfilerBody extends StatelessWidget {
  const _NetworkProfilerBody({required this.controller});

  final NetworkController controller;

  @override
  Widget build(BuildContext context) {
    final splitAxis = SplitPane.axisFor(context, 1.0);
    return SplitPane(
      initialFractions: splitAxis == Axis.horizontal ? [0.6, 0.4] : [0.5, 0.5],
      minSizes: const [200, 200],
      axis: splitAxis,
      children: [
        ValueListenableBuilder<List<NetworkRequest>>(
          valueListenable: controller.filteredData,
          builder: (context, filteredRequests, _) {
            return NetworkRequestsTable(
              networkController: controller,
              requests: filteredRequests,
              searchMatchesNotifier: controller.searchMatches,
              activeSearchMatchNotifier: controller.activeSearchMatch,
            );
          },
        ),
        NetworkRequestInspector(controller),
      ],
    );
  }
}

class NetworkRequestsTable extends StatelessWidget {
  const NetworkRequestsTable({
    super.key,
    required this.networkController,
    required this.requests,
    required this.searchMatchesNotifier,
    required this.activeSearchMatchNotifier,
  });

  static final methodColumn = MethodColumn();
  static final addressColumn = AddressColumn();
  static final statusColumn = StatusColumn();
  static final typeColumn = TypeColumn();
  static final durationColumn = DurationColumn();
  static final timestampColumn = TimestampColumn();
  static final actionsColumn = ActionsColumn();
  static final columns = <ColumnData<NetworkRequest>>[
    methodColumn,
    addressColumn,
    statusColumn,
    typeColumn,
    durationColumn,
    timestampColumn,
    actionsColumn,
  ];

  final NetworkController networkController;
  final List<NetworkRequest> requests;
  final ValueListenable<List<NetworkRequest>> searchMatchesNotifier;
  final ValueListenable<NetworkRequest?> activeSearchMatchNotifier;

  @override
  Widget build(BuildContext context) {
    return RoundedOutlinedBorder(
      clip: true,
      // TODO(kenz): use SearchableFlatTable instead.
      child: FlatTable<NetworkRequest?>(
        keyFactory: (NetworkRequest? data) => ValueKey<NetworkRequest?>(data),
        data: requests,
        dataKey: 'network-requests',
        searchMatchesNotifier: searchMatchesNotifier,
        activeSearchMatchNotifier: activeSearchMatchNotifier,
        autoScrollContent: true,
        columns: columns,
        selectionNotifier: networkController.selectedRequest,
        defaultSortColumn: timestampColumn,
        defaultSortDirection: SortDirection.ascending,
        onItemSelected: (item) {
          if (item is DartIOHttpRequestData) {
            unawaited(item.getFullRequestData());
            networkController.resetDropDown();
          }
        },
      ),
    );
  }
}

class AddressColumn extends ColumnData<NetworkRequest>
    implements ColumnRenderer<NetworkRequest> {
  AddressColumn()
    : super.wide(
        'Address',
        minWidthPx: scaleByFontFactor(isEmbedded() ? 100 : 150.0),
        showTooltip: true,
      );

  @override
  String getValue(NetworkRequest dataObject) {
    return dataObject.uri;
  }

  @override
  Widget build(
    BuildContext context,
    NetworkRequest data, {
    bool isRowSelected = false,
    bool isRowHovered = false,
    VoidCallback? onPressed,
  }) {
    final value = getDisplayValue(data);

    return SelectableText(
      value,
      maxLines: 1,
      style: const TextStyle(overflow: TextOverflow.ellipsis),
      // [onPressed] needs to be passed along to [SelectableText] so that a
      // click on the text will still trigger the [onPressed] action for the
      // row.
      onTap: onPressed,
    );
  }
}

class MethodColumn extends ColumnData<NetworkRequest> {
  MethodColumn() : super('Method', fixedWidthPx: scaleByFontFactor(60));

  @override
  String getValue(NetworkRequest dataObject) {
    return dataObject.method;
  }
}

class ActionsColumn extends ColumnData<NetworkRequest>
    implements ColumnRenderer<NetworkRequest> {
  ActionsColumn()
    : super(
        '',
        fixedWidthPx: scaleByFontFactor(32),
        alignment: ColumnAlignment.right,
      );

  static const _actionSplashRadius = 16.0;

  @override
  bool get supportsSorting => false;

  @override
  bool get includeHeader => false;

  @override
  String getValue(NetworkRequest dataObject) {
    return '';
  }

  List<PopupMenuItem> _buildOptions(NetworkRequest data) {
    return [
      if (data is DartIOHttpRequestData) ...[
        PopupMenuItem(
          child: const Text('Copy as URL'),
          onTap: () {
            unawaited(
              copyToClipboard(
                data.uri,
                successMessage: 'Copied the URL to the clipboard',
              ),
            );
          },
        ),
        PopupMenuItem(
          child: const Text('Copy as cURL'),
          onTap: () {
            unawaited(
              copyToClipboard(
                CurlCommand.from(data).toString(),
                successMessage: 'Copied the cURL command to the clipboard',
              ),
            );
          },
        ),
      ],
    ];
  }

  @override
  Widget build(
    BuildContext context,
    NetworkRequest data, {
    bool isRowSelected = false,
    bool isRowHovered = false,
    VoidCallback? onPressed,
  }) {
    final options = _buildOptions(data);

    // Only show the actions button when there are options and the row is
    // currently selected.
    if (options.isEmpty || !isRowSelected) return const SizedBox.shrink();

    return PopupMenuButton(
      icon: const Icon(Icons.more_vert),
      padding: const EdgeInsets.symmetric(horizontal: densePadding),
      splashRadius: _actionSplashRadius,
      tooltip: '',
      itemBuilder: (context) => options,
    );
  }
}

class StatusColumn extends ColumnData<NetworkRequest>
    implements ColumnRenderer<NetworkRequest> {
  StatusColumn()
    : super(
        'Status',
        alignment: ColumnAlignment.right,
        headerAlignment: TextAlign.right,
        fixedWidthPx: scaleByFontFactor(50),
      );

  @override
  String? getValue(NetworkRequest dataObject) {
    return dataObject.status;
  }

  @override
  String getDisplayValue(NetworkRequest dataObject) {
    return dataObject.status == null ? '--' : dataObject.status.toString();
  }

  @override
  Widget build(
    BuildContext context,
    NetworkRequest data, {
    bool isRowSelected = false,
    bool isRowHovered = false,
    VoidCallback? onPressed,
  }) {
    final theme = Theme.of(context);
    return Text(
      getDisplayValue(data),
      style:
          data.didFail
              ? TextStyle(color: theme.colorScheme.error)
              : theme.regularTextStyle,
    );
  }
}

class TypeColumn extends ColumnData<NetworkRequest> {
  TypeColumn()
    : super(
        'Type',
        alignment: ColumnAlignment.right,
        headerAlignment: TextAlign.right,
        fixedWidthPx: scaleByFontFactor(50),
      );

  @override
  String getValue(NetworkRequest dataObject) {
    return dataObject.type;
  }

  @override
  String getDisplayValue(NetworkRequest dataObject) {
    return dataObject.type;
  }
}

class DurationColumn extends ColumnData<NetworkRequest> {
  DurationColumn()
    : super(
        'Duration',
        alignment: ColumnAlignment.right,
        headerAlignment: TextAlign.right,
        fixedWidthPx: scaleByFontFactor(75),
      );

  @override
  int? getValue(NetworkRequest dataObject) {
    return dataObject.duration?.inMilliseconds;
  }

  @override
  String getDisplayValue(NetworkRequest dataObject) {
    final ms = getValue(dataObject);
    return ms == null
        ? 'Pending'
        : durationText(Duration(milliseconds: ms), fractionDigits: 0);
  }
}

class TimestampColumn extends ColumnData<NetworkRequest> {
  TimestampColumn()
    : super(
        'Timestamp',
        alignment: ColumnAlignment.right,
        headerAlignment: TextAlign.right,
        fixedWidthPx: scaleByFontFactor(115),
      );

  @override
  DateTime? getValue(NetworkRequest dataObject) {
    return dataObject.startTimestamp;
  }

  @override
  String getDisplayValue(NetworkRequest dataObject) {
    return formatDateTime(dataObject.startTimestamp!);
  }
}
