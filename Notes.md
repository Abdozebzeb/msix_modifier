- Build Commands:
````
dart pub get
dart compile exe bin/main.dart -o build/msix_modifier.exe
xcopy /E /I assets build\assets
copy config.md build\config.md
````
- Run command:
````
./build\msix_modifier.exe
````