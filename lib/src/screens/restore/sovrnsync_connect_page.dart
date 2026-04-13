import 'dart:convert';
import 'dart:io';

import 'package:cake_wallet/routes.dart';
import 'package:cake_wallet/src/screens/base_page.dart';
import 'package:cake_wallet/src/widgets/base_text_form_field.dart';
import 'package:cake_wallet/src/widgets/primary_button.dart';
import 'package:cake_wallet/src/widgets/scrollable_with_bottom_section.dart';
import 'package:flutter/material.dart';

class SovrnSyncConnectPage extends BasePage {
  SovrnSyncConnectPage()
      : _ipController = TextEditingController(),
        _portController = TextEditingController(text: '18083');

  final TextEditingController _ipController;
  final TextEditingController _portController;

  @override
  String get title => 'Connect to Sovrnsync';

  @override
  Widget body(BuildContext context) {
    return _SovrnSyncConnectBody(
      ipController: _ipController,
      portController: _portController,
    );
  }
}

class _SovrnSyncConnectBody extends StatefulWidget {
  const _SovrnSyncConnectBody({
    required this.ipController,
    required this.portController,
  });

  final TextEditingController ipController;
  final TextEditingController portController;

  @override
  State<_SovrnSyncConnectBody> createState() => _SovrnSyncConnectBodyState();
}

class _SovrnSyncConnectBodyState extends State<_SovrnSyncConnectBody> {
  bool _isTestingConnection = false;
  bool _connectionSuccess = false;
  String? _statusMessage;
  Color _statusColor = Colors.transparent;

  Future<void> _testConnection() async {
    final ip = widget.ipController.text.trim();
    final port = widget.portController.text.trim();

    if (ip.isEmpty || port.isEmpty) {
      setState(() {
        _statusMessage = 'Please enter both IP and port';
        _statusColor = Colors.red;
        _connectionSuccess = false;
      });
      return;
    }

    setState(() {
      _isTestingConnection = true;
      _statusMessage = null;
      _connectionSuccess = false;
    });

    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 10);

      final uri = Uri.parse('http://$ip:$port/json_rpc');
      final request = await httpClient.postUrl(uri);
      request.headers.contentType = ContentType.json;

      final body = json.encode({
        'jsonrpc': '2.0',
        'id': '0',
        'method': 'get_version',
        'params': {},
      });

      request.write(body);
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      httpClient.close();

      final jsonParsed = json.decode(responseBody) as Map<String, dynamic>;

      if (jsonParsed.containsKey('result')) {
        setState(() {
          _connectionSuccess = true;
          _statusMessage = 'Connected successfully';
          _statusColor = Colors.green;
        });
      } else {
        setState(() {
          _connectionSuccess = false;
          _statusMessage = 'Unexpected response from server';
          _statusColor = Colors.red;
        });
      }
    } catch (e) {
      setState(() {
        _connectionSuccess = false;
        _statusMessage = 'Connection failed: ${e.toString()}';
        _statusColor = Colors.red;
      });
    } finally {
      setState(() => _isTestingConnection = false);
    }
  }

  void _connect() {
    Navigator.pushNamedAndRemoveUntil(
      context,
      Routes.dashboard,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScrollableWithBottomSection(
      contentPadding: EdgeInsets.all(24),
      content: Column(
        children: [
          BaseTextFormField(
            controller: widget.ipController,
            hintText: 'Tailscale IP',
            keyboardType: TextInputType.url,
          ),
          Padding(
            padding: EdgeInsets.only(top: 20),
            child: BaseTextFormField(
              controller: widget.portController,
              hintText: 'Port',
              keyboardType: TextInputType.number,
            ),
          ),
          if (_statusMessage != null)
            Padding(
              padding: EdgeInsets.only(top: 20),
              child: Text(
                _statusMessage!,
                style: TextStyle(
                  color: _statusColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
      bottomSectionPadding: EdgeInsets.only(left: 24, right: 24, bottom: 24),
      bottomSection: Column(
        children: [
          LoadingPrimaryButton(
            onPressed: _testConnection,
            text: 'Test Connection',
            color: Theme.of(context).colorScheme.surfaceContainer,
            textColor: Theme.of(context).colorScheme.onSecondaryContainer,
            isLoading: _isTestingConnection,
          ),
          SizedBox(height: 12),
          PrimaryButton(
            onPressed: _connect,
            text: 'Connect',
            color: Theme.of(context).colorScheme.primary,
            textColor: Theme.of(context).colorScheme.onPrimary,
            isDisabled: !_connectionSuccess,
          ),
        ],
      ),
    );
  }
}
