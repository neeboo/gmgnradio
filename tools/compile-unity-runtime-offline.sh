#!/bin/zsh
# Compile real runtime sources against installed Unity/project assemblies. Never launches Unity.
set -eu
cd "${0:A:h:h}"
task_unity=/Applications/Unity/Hub/Editor/6000.6.0f1/Unity.app/Contents/Resources/Scripting
task_output=$(mktemp -d /private/tmp/gmgn-unity-runtime-compile.XXXXXX)
task_symbols=UNITY_STANDALONE_OSX,UNITY_STANDALONE,UNITY_6000_0_OR_NEWER,GMGN_UMT,GMGN_UNIVRM
[[ "${1:-}" == "--editor" ]] && task_symbols+=,UNITY_EDITOR,UNITY_EDITOR_OSX
task_refs=()
for task_file in "$task_unity"/NetStandard/ref/2.1.0/*.dll "$task_unity"/Managed/UnityEngine/*.dll; do
  task_refs+=("-r:$task_file")
done
task_refs+=("-r:$task_unity/NetStandard/compat/2.1.0/shims/netfx/mscorlib.dll")
for task_file in apps/unity-player/Library/ScriptAssemblies/*.dll; do
  case "${task_file:t}" in
    Assembly-CSharp*|GMGN.*|*Editor*|*Tests*) continue ;;
  esac
  task_refs+=("-r:$task_file")
done
# GaussianBridge's asmref assigns it to the third-party GaussianSplatting assembly,
# where it accesses internal types. Use that real compiled assembly here.
task_sources=("${(@f)$(rg --files apps/unity-player/Assets/GMGN | rg '\.cs$' | rg -v '/Editor/|/GaussianBridge/')}" )
"$task_unity/DotNetSdk/dotnet" "$task_unity/DotNetSdk/sdk/8.0.318/Roslyn/bincore/csc.dll" \
  -nologo -nostdlib+ -target:library -langversion:latest -unsafe+ \
  "-define:$task_symbols" \
  "-out:$task_output/GMGN.Runtime.dll" "${task_refs[@]}" "${task_sources[@]}"
print -r -- "Compiled real GMGN runtime sources: $task_output/GMGN.Runtime.dll"
if [[ "${1:-}" == "--editor" ]]; then
  task_editor_refs=("${task_refs[@]}" "-r:$task_output/GMGN.Runtime.dll")
  for task_file in apps/unity-player/Library/ScriptAssemblies/*Editor*.dll(N); do
    case "${task_file:t}" in Assembly-CSharp*|GMGN.*|*Tests*) continue ;; esac
    task_editor_refs+=("-r:$task_file")
  done
  for task_file in "$task_unity"/Managed/UnityEngine/UnityEditor*.dll(N); do
    [[ -f "$task_file" ]] && task_editor_refs+=("-r:$task_file")
  done
  task_editor_sources=("${(@f)$(rg --files apps/unity-player/Assets/GMGN | rg '/Editor/.*\.cs$')}" )
  "$task_unity/DotNetSdk/dotnet" "$task_unity/DotNetSdk/sdk/8.0.318/Roslyn/bincore/csc.dll" \
    -nologo -nostdlib+ -target:library -langversion:latest -unsafe+ \
    -define:UNITY_EDITOR,UNITY_EDITOR_OSX,UNITY_STANDALONE_OSX,UNITY_STANDALONE,UNITY_6000_0_OR_NEWER \
    "-out:$task_output/GMGN.Editor.dll" "${task_editor_refs[@]}" "${task_editor_sources[@]}"
  print -r -- "Compiled real GMGN Editor sources: $task_output/GMGN.Editor.dll"
fi
