# Generated asset resolver regression

Compiles the actual Unity resolver without starting the Editor or game. Requires the Unity project's installed Newtonsoft DLL and a .NET 8 SDK (Unity 6000.6 bundles one).

```sh
/Applications/Unity/Hub/Editor/6000.6.0f1/Unity.app/Contents/Resources/Scripting/DotNetSdk/dotnet build tools/generated-asset-regression/GeneratedAssetRegression.csproj --configuration Release --property:BaseIntermediateOutputPath=/tmp/gmgn-generated-resolver-obj/ --property:OutputPath=/tmp/gmgn-generated-resolver-bin/ --verbosity quiet
/Applications/Unity/Hub/Editor/6000.6.0f1/Unity.app/Contents/Resources/Scripting/DotNetSdk/dotnet /tmp/gmgn-generated-resolver-bin/GeneratedAssetRegression.dll
```

Creates/removes only a new UUID fixture directory under workspace `tmp/`. It checks valid receipt identity/hash/path, fresh resolver recovery, wrong world, external path, wrong source wish, same-length corruption, and symbolic links. It does not test Rust networking, provider generation or GLTFast visual rendering.

Native integration DTO:

```json
{"worldID":"selected-world","revision":1,"entries":[{"objectID":"wish-prop-id","sourceWishID":"wish-uuid","taskID":"core-task-uuid","assetID":"sha256:64-lowercase-hex","sha256":"64-lowercase-hex","bytes":123,"localModelPath":"explicit-root/gmgn radio/TaskService/core-task-uuid.glb"}]}
```

Build this catalog exclusively from matching current-world inventory and real completed Rust task receipts. Renderer `SetGeneratedAssets` validates identity, confines output to the exact UUID filename in explicit data root, rejects links and rechecks bytes/hash on background resolution. Backup package validation is unchanged. Root sends `InventoryUpdated` and supplies `BeginInventoryPlacement`; visible world objects and pending inventory come from current Rust state, not stale backup state.
