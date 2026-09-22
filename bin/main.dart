import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

void main() async {
  print('====================================');
  print('       MSIX File Association Tool    ');
  print('====================================\n');

  // 1. Locate makeappx.exe
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final makeappxPath = _findMakeAppx(exeDir);
  if (makeappxPath == null) {
    print('❌ Error: Could not find makeappx.exe in "assets" folder.');
    _pauseAndExit();
    return;
  }
  print('✔ Found makeappx: $makeappxPath');

  // 2. Select MSIX file via Windows Dialog
  print('\nPlease choose the input .msix file from the dialog...');
  final inputMsixPath = await _pickFile(
    title: 'Select MSIX Package',
    filter: 'MSIX Files (*.msix)|*.msix|All Files (*.*)|*.*',
  );

  if (inputMsixPath == null || inputMsixPath.isEmpty) {
    print('❌ No file selected. Exiting.');
    _pauseAndExit();
    return;
  }
  print('✔ Selected MSIX: $inputMsixPath');

  // 3. Read config.md
  final configFile = _findConfigFile(exeDir);
  if (configFile == null || !configFile.existsSync()) {
    print('❌ Error: config.md was not found in the executable directory or project root.');
    _pauseAndExit();
    return;
  }
  print('✔ Reading config from: ${configFile.path}');
  final associations = _parseConfig(configFile.readAsStringSync());

  if (associations.isEmpty) {
    print('❌ No valid file extensions found in config.md.');
    _pauseAndExit();
    return;
  }
  print('✔ Loaded ${associations.length} file extension(s) to add:');
  for (var a in associations) {
    print('   - ${a.extension} (${a.displayName})');
  }

  // 4. Select Output Directory
  print('\nPlease choose the output folder to save the modified package...');
  final outputDir = await _pickFolder(title: 'Select Output Directory');
  if (outputDir == null || outputDir.isEmpty) {
    print('❌ No output directory selected. Exiting.');
    _pauseAndExit();
    return;
  }
  print('✔ Output folder: $outputDir');

  // 5. Create a temporary folder for extraction
  final tempExtractDir = Directory.systemTemp.createTempSync('msix_extract_');
  try {
    // Extract MSIX
    print('\n[1/3] Extracting MSIX package...');
    final unpackResult = await Process.run(makeappxPath, [
      'unpack',
      '/p', inputMsixPath,
      '/d', tempExtractDir.path,
      '/o',
    ]);

    if (unpackResult.exitCode != 0) {
      print('❌ Unpack failed:\n${unpackResult.stderr}\n${unpackResult.stdout}');
      _pauseAndExit();
      return;
    }

    // 6. Modify AppxManifest.xml
    print('[2/3] Updating AppxManifest.xml with file associations...');
    final manifestFile = File(p.join(tempExtractDir.path, 'AppxManifest.xml'));
    if (!manifestFile.existsSync()) {
      print('❌ Error: AppxManifest.xml not found inside package.');
      _pauseAndExit();
      return;
    }

    _updateManifest(manifestFile, associations);

    // 7. Repack MSIX
    print('[3/3] Repacking modified MSIX...');
    final originalName = p.basenameWithoutExtension(inputMsixPath);
    final finalOutputPath = p.join(outputDir, '${originalName}_Modified.msix');

    final packResult = await Process.run(makeappxPath, [
      'pack',
      '/d', tempExtractDir.path,
      '/p', finalOutputPath,
      '/o',
    ]);

    if (packResult.exitCode != 0) {
      print('❌ Repack failed:\n${packResult.stderr}\n${packResult.stdout}');
      _pauseAndExit();
      return;
    }

    print('\n====================================');
    print('🎉 SUCCESS!');
    print('Modified MSIX created at:\n$finalOutputPath');
    print('====================================');
  } finally {
    // Clean up temporary extracted folder
    if (tempExtractDir.existsSync()) {
      tempExtractDir.deleteSync(recursive: true);
    }
  }

  _pauseAndExit();
}

// ---------------------------------------------------------------------------
// Helper: Update AppxManifest.xml
// ---------------------------------------------------------------------------
void _updateManifest(File manifestFile, List<FileAssociation> associations) {
  final content = manifestFile.readAsStringSync();
  final document = XmlDocument.parse(content);

  // Ensure xmlns:uap namespace is defined on the root <Package>
  final packageElement = document.rootElement;
  final hasUap = packageElement.attributes.any(
      (attr) => attr.name.prefix == 'xmlns' && attr.name.local == 'uap');
  if (!hasUap) {
    packageElement.attributes.add(
      XmlAttribute(XmlName('uap', 'xmlns'), 'http://schemas.microsoft.com/appx/manifest/uap/windows10'),
    );
  }

  // Find <Applications> -> <Application>
  final appElement = document.findAllElements('Application').firstOrNull;
  if (appElement == null) {
    throw Exception('No <Application> element found in AppxManifest.xml');
  }

  // Find or create <Extensions> tag inside <Application>
  var extensionsElement = appElement.findElements('Extensions').firstOrNull;
  if (extensionsElement == null) {
    extensionsElement = XmlElement(XmlName('Extensions'));
    appElement.children.add(extensionsElement);
  }

  // Append new <uap:Extension> blocks
  for (var item in associations) {
    // Alphanumeric name without dots (required by Windows)
    final sanitizedName = item.extension.replaceAll('.', '').toLowerCase() + 'file';

    final extensionXml = XmlElement(
      XmlName('uap:Extension'),
      [XmlAttribute(XmlName('Category'), 'windows.fileTypeAssociation')],
      [
        XmlElement(
          XmlName('uap:FileTypeAssociation'),
          [XmlAttribute(XmlName('Name'), sanitizedName)],
          [
            XmlElement(XmlName('uap:SupportedFileTypes'), [], [
              XmlElement(XmlName('uap:FileType'), [], [XmlText(item.extension)])
            ]),
            XmlElement(XmlName('uap:DisplayName'), [], [XmlText(item.displayName)]),
            XmlElement(XmlName('uap:EditFlags'), [XmlAttribute(XmlName('OpenIsSafe'), 'true')])
          ],
        )
      ],
    );

    extensionsElement.children.add(extensionXml);
  }

  // Write updated manifest
  manifestFile.writeAsStringSync(document.toXmlString(pretty: true, indent: '  '));
}

// ---------------------------------------------------------------------------
// Helper: Parse Config Markdown
// ---------------------------------------------------------------------------
class FileAssociation {
  final String extension;
  final String displayName;
  FileAssociation({required this.extension, required this.displayName});
}

List<FileAssociation> _parseConfig(String text) {
  final results = <FileAssociation>[];
  final blocks = text.split(RegExp(r'-\s*extension:\s*'));

  for (var block in blocks.skip(1)) {
    final lines = block.split('\n');
    if (lines.isEmpty) continue;

    var ext = lines[0].trim().replaceAll('"', '').replaceAll("'", "");
    if (!ext.startsWith('.')) ext = '.$ext';

    // Using triple-quoted raw string to prevent parsing conflicts
    final nameMatch = RegExp(r'''display_name:\s*["']?([^"'\r\n]+)["']?''').firstMatch(block);
    final displayName = nameMatch?.group(1)?.trim() ?? ext;

    results.add(FileAssociation(extension: ext, displayName: displayName));
  }
  return results;
}

// ---------------------------------------------------------------------------
// Helper: File and Folder Dialogs using Windows PowerShell
// ---------------------------------------------------------------------------
Future<String?> _pickFile({required String title, required String filter}) async {
  final script = '''
  Add-Type -AssemblyName System.Windows.Forms
  \$f = New-Object System.Windows.Forms.OpenFileDialog
  \$f.Filter = "$filter"
  \$f.Title = "$title"
  if (\$f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      Write-Output \$f.FileName
  }
  ''';
  final result = await Process.run('powershell', ['-NoProfile', '-Command', script]);
  final path = result.stdout.toString().trim();
  return path.isNotEmpty ? path : null;
}

Future<String?> _pickFolder({required String title}) async {
  final script = '''
  Add-Type -AssemblyName System.Windows.Forms
  \$f = New-Object System.Windows.Forms.FolderBrowserDialog
  \$f.Description = "$title"
  if (\$f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      Write-Output \$f.SelectedPath
  }
  ''';
  final result = await Process.run('powershell', ['-NoProfile', '-Command', script]);
  final path = result.stdout.toString().trim();
  return path.isNotEmpty ? path : null;
}

// ---------------------------------------------------------------------------
// Helper: Find makeappx.exe and config.md
// ---------------------------------------------------------------------------
String? _findMakeAppx(String exeDir) {
  // 1. Check local assets folder first
  final localCandidates = [
    p.join(exeDir, 'assets', 'makeappx.exe'),
    p.join(exeDir, 'makeappx.exe'),
    p.join(exeDir, '..', 'assets', 'makeappx.exe'),
    p.join(Directory.current.path, 'assets', 'makeappx.exe'),
  ];
  for (var path in localCandidates) {
    if (File(path).existsSync()) return path;
  }

  // 2. Automatically locate makeappx in Windows Kits if local one is absent/broken
  final sdkBase = Directory(r'C:\Program Files (x86)\Windows Kits\10\bin');
  if (sdkBase.existsSync()) {
    final versions = sdkBase
        .listSync()
        .whereType<Directory>()
        .where((d) => RegExp(r'^\d+\.').hasMatch(p.basename(d.path)))
        .toList();

    // Sort descending to get the newest SDK version (e.g. 10.0.26100.0)
    versions.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));

    for (var versionDir in versions) {
      final x64Path = p.join(versionDir.path, 'x64', 'makeappx.exe');
      if (File(x64Path).existsSync()) {
        return x64Path;
      }
    }
  }

  return null;
}

File? _findConfigFile(String exeDir) {
  final candidates = [
    p.join(exeDir, 'config.md'),
    p.join(exeDir, '..', 'config.md'),
    p.join(Directory.current.path, 'config.md'),
  ];
  for (var path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

void _pauseAndExit() {
  print('\nPress ENTER to exit...');
  stdin.readLineSync();
}