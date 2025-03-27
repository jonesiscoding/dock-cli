#!/bin/zsh

specialApps="special_apps.json"
webappPattern="(com.apple.Safari.WebApp|com.google.Chrome.app|com.microsoft.edgemac.app)"
plistFile="com.apple.dock.plist"
plistDir="Library/Preferences"
position="0"
section="persistent-apps"

specialApps=$(cat <<EOF
{
  "acrobat": {
    "paths":
      [
          "/Applications/Adobe Acrobat DC/Adobe Acrobat.app",
          "/Applications/Adobe Acrobat XI Pro/Adobe Acrobat Pro.app",
          "/Applications/Adobe Acrobat Reader DC.app",
          "/Applications/Adobe Acrobat Reader.app",
          "/Applications/Adobe Acrobat.app",
          "/System/Applications/Preview.app"
      ]
  },
  "adobe": {
    "paths":
      [
        "/Applications/Adobe ###name### ###year###/Adobe ###name### ###year###.app",
        "/Applications/Adobe ###name### ###year###/Adobe ###name###.app",
        "/Applications/Adobe ###name###/Adobe ###name###.app",
        "/Applications/Adobe ###name### CC ###year###/Adobe ###name### ###year###.app",
        "/Applications/Adobe ###name### CC ###year###/Adobe ###name###.app",
        "/Applications/Adobe ###name### CC/Adobe ###name###.app"
      ]
  },
  "system": {
    "paths":
      [
        "/Applications/###name###",
        "/Applications/Utilities/###name###",
        "/System/Applications/###name###",
        "/System/Applications/Utilities/###name###",
        "/System/Applications/Utilities/###name###",
        "/System/Library/CoreServices/Applications/###name###",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/###name###"
      ]
  }
}
EOF
)

## region ###################################### MDM Functions

# @description Evaluates if the script is being run by Jamf
# @retval 0 Run via Jamf
# @retval 1 Not run via Jamf
function __isJamfRun() {
  local cName firstCharFirstArg
  cName=$(/usr/sbin/scutil --get ComputerName)
  firstCharFirstArg=$(/usr/bin/printf '%s' "$1" | /usr/bin/cut -c 1)
  if [[ "$firstCharFirstArg" == "/" ]] && [[ "$2" == "$cName" ]]; then
    return 0
  else
    return 1
  fi
}

if __isJamfRun "$@"; then
  # shellcheck disable=SC2034
  jamfMountPoint="$1"
  # shellcheck disable=SC2034
  jamfHostName="$2"
  # shellcheck disable=SC2034
  jamfUser="$3"
  # Remove Jamf Arguments
  shift 3
  # Blank first Output Line for Prettier Jamf Logs
  echo ""
fi

## endregion ################################### End Jamf Functions

## region ###################################### File Functions

# @description Removes the file:// schema, specific encoding, and trailing slashes.
# @arg $1 string The File URL to normalize
# @stdout string Normalized String
function file::normalize() {
  echo "$1" | sed 's#file://##' | sed 's#%20# #g' | sed 's#%7C#|#g' | sed -E 's#/$##'
}

# @description Evaluates if the given path is an app bundle, excluding webapps.
# @arg $1 string Path
# @exitcode 0 Yes
# @exitcode 1 No
function posix::is::app() {
  if test -f "$1/Contents/Info.plist"; then
    ! posix::is::webapp "$1"
  else
    echo "$1" | grep -E "^/System/Applications" | grep -q -E ".app$"
  fi
}

# @description Evaluates if the given path is a webapp bundle
# @arg $1 string Path
# @exitcode 0 Yes
# @exitcode 1 No
function posix::is::webapp() {
  if test -f "$1/Contents/Info.plist"; then
    defaults read "$1/Contents/Info.plist" CFBundleIdentifier | grep -qE "$webappPattern" && return 0
  fi

  return 1
}

# @description Evaluates if the given path is a webapp, crwebloc, or webloc.
# @arg $1 string Path
# @exitcode 0 Yes
# @exitcode 1 No
function posix::is::url() {
  if posix::is::webapp "$1"; then
    return 0
  elif echo "$1" | grep -qE ".[cr]?webloc$"; then
    return 0
  else
    return 1
  fi
}

## endregion ################################### End File Functions

## region ###################################### App Handling Functions

function app::adobe::name() {
  appName=$(dirname "$1")
  if [[ "$appName" != "/Applications" ]]; then
    basename "$appName"
  else
    basename "$1" .app
  fi
}

# @description Evaluates if the given path is a webapp bundle
# @arg $1 string JSON array of paths
# @stdout string First Existing Path
# @exitcode 0 Path Found
# @exitcode 1 No Path Found
function app::paths::exists() {
  local i
  jq -c '.[]' <<< "$1" | while read i; do
    if [ -e "$i" ]; then
      echo "$i" && return 0
    fi
  done

  return 1
}

# @description Returns the path to a PDF reading app, typically either Acrobat Pro, Acrobat Reader, or Preview.
# @noargs
# @stdout string Path to App
# @exitcode 0 Path Found
# @exitcode 1 No Path Found
function app::special::acrobat() {
  app::paths::exists "$(jq '.acrobat.paths' <<< "$specialApps")"
}

# @description Returns the path to the given Adobe app. If a year is given as part of the parameter, only apps named
# with that year or older will be considered.  No app older than 2014 is considered.
# @arg $1 string Lowercase single-word app description, with or without the year (photoshop-2025)
# @stdout string Path to App
# @exitcode 0 Path Found
# @exitcode 1 No Path Found
function app::special::adobe() {
  local adobePaths name year

  name=$(echo "$1" | awk -F'-' '{ print $1 }')
  name=$(echo "${(C)name}" | sed 's#Indesign#InDesign#' | sed 's#Premierepro#Premiere Pro#' | sed 's#Lightroomcc#Lightroom CC#' | sed 's#Xd#XD#')
  year=$(echo "$1" | awk -F'-' '{ print $2 }')
  [ -z "$year" ] && year=$(date +"%Y")

  adobePaths="$(jq '.adobe.paths' <<< "$specialApps")"
  jq -r -c '.[]' <<< "$adobePaths" | while read i; do
    for yr in $(seq $year 2014); do
      testMe=$(echo "$i" | sed "s/###name###/$name/g" | sed "s/###year###/$yr/g")
      if [ -n "$testMe" ] && [ -e "$testMe" ]; then
        echo "$testMe" && return 0
      fi
    done
  done

  return 1
}

# @description Returns the path to the given app, checking the paths in specialApps.system.paths.
# @arg $1 string Slug for app; dash-separated (screen-sharing)
# @stdout string Path to App
# @exitcode 0 Path Found
# @exitcode 1 No Path Found
function app::system() {
  local name

  name=$(echo "$1" | awk -F'-' '{ print $1 }' | sed 's/-/ /')
  systemPaths="$(jq '.system.paths' <<< "$specialApps")"
  jq -r -c '.[]' <<< "$systemPaths" | while read i; do
    testMe=$(echo "$i" | sed "s/###name###/$name/g")
    if [ -n "$testMe" ] && [ -e "$testMe" ]; then
      echo "$testMe" && return 0
    fi
  done

  return 1
}

# @description Returns the path to the given special app, checking the paths in specialApps.
# @arg $1 string Slug for app; dash-separated (screen-sharing)
# @stdout string Path to App
# @exitcode 0 Path Found
# @exitcode 1 No Path Found
function app::special() {
  local app

  app="$1"

  case "$app" in
    safari)
      echo "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app" ;;
    screen-sharing)
      if [ -e "/System/Library/CoreServices/Applications/Screen Sharing.app" ]; then
        echo "/System/Library/CoreServices/Applications/Screen Sharing.app"
      else
        echo "/System/Applications/Utilities/Screen Sharing.app"
      fi
      ;;
    acrobat)
      app::special::acrobat ;;
    photoshop* | indesign* | illustrator* | bridge* | lightroom* | animate* | after* | xd | dimension )
      app::special::adobe "$app";;
    * )
      appJson=$(jq ".\"$app\"//empty" <<< "$specialApps")
      if [ -n "$appJson" ]; then
        entryPath=$(jq '.path//empty' <<< "$appJson")
        if [ -n "$entryPath" ]; then
          echo "$entryPath"
        else
          entryPaths=$(jq '.paths//empty' <<< "$appJson")
          if [ -n "$entryPaths" ]; then
            app::paths::exists "$entryPaths"
          fi
        fi
      fi
  esac
}

# @description Returns the path to the given app slug or name
# @arg $1 string Slug or Name for app
# @stdout string Path to App
# @exitcode 0 Path Found
# @exitcode 1 No Path Found
function app::resolve() {
  name="$1"
  app="$name"

  # Absolute Path
  [[ "${app:0:1}" == "/" ]] && echo "$app" && return 0

  # Special Apps
  if is-special "$app"; then
    special=$(app::special "$app")
    if [ -n "$special" ]; then
      echo "$special" && return 0
    fi
  fi

  # Extension
  [ -z "$app:e" ] && app="${app}.app"

  # User Path
  [[ "${app:0:1}" == "~" ]] && app=$(echo "$app" | sed "s#~#$myUserDir#")

  # Test for Existence
  if [ -e "$app" ]; then
    echo "$app" && return 0
  else
    system=$(app::system "$app")
    if [ -n "$system" ]; then
      echo "$system" && return 0
    fi
  fi

  return 1
}

# @description Returns a name or slug for the given app bundle
# @arg $1 string Path to App
# @stdout string Summary String
# @exitcode 0 Path Found
# @exitcode 1 No Path Found
function app::summarize() {
  local posix

  posix="$1"
  if echo "$posix" | grep -q -E "^/Users"; then
    # User App
    echo "$posix" | sed "s#$myUserDir#~#"
  elif echo "$posix" | grep -q "Acrobat"; then
    # Acrobat App
    echo "acrobat"
  elif echo "$posix" | grep -q "Adobe"; then
    # Other Adobe App
    year="$(date +"%Y")"
    if echo "$posix" | grep -q "$(date +"%Y")"; then
      app::adobe::name "$posix" | sed "s/$year//" | sed 's/Adobe //' | tr '[:upper:]' '[:lower:]'
    else
      app::adobe::name "$posix" | sed -E "s/ ([0-9]+)/-\1/" | sed 's/Adobe //' | tr '[:upper:]' '[:lower:]'
    fi
  elif echo "$posix" | grep -q -E "Safari\.app$"; then
    # Safari
    echo "safari"
  elif echo "$posix" | grep -q -E "Screen Sharing\.app$"; then
    # Screen Sharing
    echo "screen-sharing"
  else
    # Other Apps
    systemPaths="$(jq '.system.paths' <<< "$specialApps")"
    jq -r -c '.[]' <<< "$systemPaths" | while read i; do
      replace=$(echo "$i" | sed "s/###name###//g")
      if echo "$posix" | grep -q -E "^$replace"; then
        echo "$posix" | sed -E "s#^$replace##" | sed -E 's#.app$##'
      fi
    done
  fi
}

## endregion ################################### End File Functions

## region ###################################### Folder Functions

# @description Converts folder 'show' constants to strings.
# @arg $1 integer Constant
# @stdout string  The String
function folder::show::toString() {
  case "$1" in
    3) echo "list" ;;
    2) echo "grid" ;;
    1) echo "fan"  ;;
    4) echo "auto" ;;
  esac
}

# @description Converts folder 'show' strings to constants.
# @arg $1 string  The String
# @stdout integer Constant
function folder::show::toInt() {
  case "$1" in
    list) echo "3" ;;
    grid) echo "2" ;;
    fan)  echo "1" ;;
    auto) echo "4" ;;
  esac
}

# @description Converts folder 'displayas' strings to constants.
# @arg $1 string  The String
# @stdout integer Constant
function folder::display::toInt() {
  case "$1" in
    folder)  echo "1" ;;
    stack)   echo "2" ;;
  esac
}

# @description Converts folder 'displayas' constants to strings.
# @arg $1 integer Constant
# @stdout string  The String
function folder::display::toString() {
  case "$1" in
    1) echo "folder"  ;;
    2) echo "stack"   ;;
  esac
}

# @description Converts folder 'arrangement' strings to constants.
# @arg $1 string  The String
# @stdout integer Constant
function folder::sort::toInt() {
  case "$1" in
    kind)            echo "5" ;;
    datecreated)     echo "4" ;;
    datemodified)    echo "3" ;;
    dateadded)       echo "2" ;;
    name)            echo "1" ;;
  esac
}

# @description Converts folder 'arrangement' constants to strings.
# @arg $1 integer Constant
# @stdout string  The String
function folder::sort::toString() {
  case "$1" in
    5) echo "kind"  ;;
    4) echo "datecreated"  ;;
    3) echo "datemodified"  ;;
    2) echo "dateadded"  ;;
    1) echo "name"   ;;
  esac
}

## endregion ################################### End Folder Functions

## region ###################################### JSON Functions

# @description Evaluates if the given string resembles a JSON object string
# @exitcode 0 Yes
# @exitcode 1 No
function json-is-object() {
  [[ "${1:0:1}" == "{" ]] && return 0
  return 1
}

# @description Evaluates if the given string resembles a JSON array string
# @exitcode 0 Yes
# @exitcode 1 No
function json-is-array() {
  [[ "${1:0:1}" == "[" ]] && return 0
  return 1
}

# @description Adds the given arguments to the given JSON object string. Multiple key/value pairs can be given.
# @arg $1 string JSON Object String
# @arg $2 string Key
# @arg $3 string Value
function json-obj-add() {
  local obj

  obj="$1"
  shift
  while [[ "$1" != "" ]]; do
    if json-is-object "$2" || json-is-array "$2"; then
      obj=$(jq ". += {\"$1\": $2 }" <<< "$obj")
    else
      obj=$(jq ". += {\"$1\": \"$2\" }" <<< "$obj")
    fi
    shift
    [ -n "$1" ] && shift
  done

  echo "$obj"
}

# @description Adds the given value to the given JSON array string
# @arg $1 string JSON array String
# @arg $2 string Value
function json-arr-add() {
  if json-is-object "$2" || json-is-array "$2"; then
    jq ". += [ $2 ]" <<< "$1"
  else
    jq ". += [ \"$2\" ]" <<< "$1"
  fi
}

## endregion ################################### JSON Functions

## region ###################################### Plist Functions

plist::tile::type() {
  /usr/libexec/PlistBuddy -c "Print :${section}:${position}:tile-type" "$dock" 2>/dev/null | grep -v "File Doesn't Exist" | grep -v "Does Not Exist"
}

plist::webapp::url() {
  /usr/libexec/PlistBuddy -c "Print :Manifest:start_url" "$1" 2>/dev/null | grep -v "File Doesn't Exist" | grep -v "Does Not Exist"
}

plist::webloc::url() {
  /usr/libexec/PlistBuddy -c "Print :URL" "$1" | grep -v "File Doesn't Exist" | grep -v "Does Not Exist"
}


plist::webloc::name() {
  curl -L -s "$(plist::webloc::url "$1")" -o - | grep '<title>' | awk -F'<title>' '{ print $2 }' | awk -F'</title>' '{ print $1 }'
}

plist::webapp::name() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleName" "$1" 2>/dev/null | grep -v "File Doesn't Exist" | grep -v "Does Not Exist"
}

plist::tile::data() {
  /usr/libexec/PlistBuddy -c "Print :${section}:${position}:tile-data:${1}" "$dock" 2>&1 | grep -v "Does Not Exist"
}

plist::tile::url() {
  plist::tile::data "url:_CFURLString"
}

plist::tile::file() {
  file::normalize "$(plist::tile::data "file-data:_CFURLString")"
}

plist::tile::label() {
  plist::tile::data "file-label" || plist::tile::data "label"
}

plist::dock::add::file() {
  local index url file label bundle json

  index="$1"
  json="$2"
  url=$(tile::url "$json")
  file="file://$(echo "$url" | sed 's# #%20#g')"
  label=$(tile::label "$json")
  bundle=$(tile::bundle "$json")

	/usr/libexec/PlistBuddy -c "add ${section}:${index} dict " "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data dict" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-data dict" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-data:_CFURLString string ${file}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-data:_CFURLStringType integer 15" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-label string ${label}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:label string ${bundle}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-type string file-tile" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:dock-extra bool false" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-type integer 41" "$dock"
}

plist::dock::add::app() {
  local index bundle json

  plist::dock::add::file "$1" "$2"

  index="$1"
  json="$2"
  bundle=$(tile::bundle "$json")

	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:bundle-identifier string ${bundle}" "$dock"
}

_findUrlApp() {
  local testUrl possible label url poss

  label="$1"
  url="$2"
  browser="$3"
  idx=1

  declare -a possible

  if echo "$browser" | grep -q -E "(any|safari)"; then
    possible[$idx]="/Applications/${label}.app" && idx=$((idx+1))
    possible[$idx]="$myUserDir/Applications/${label}.app" && idx=$((idx+1))
  fi

  if echo "$browser" | grep -q -E "(any|safari|chrome|edge)"; then
    possible[$idx]="/Applications/${label}.webloc" && idx=$((idx+1))
    possible[$idx]="$myUserDir/Applications/${label}.webloc" && idx=$((idx+1))
  fi

  if echo "$browser" | grep -q -E "(any|chrome)"; then
    possible[$idx]="/Applications/${label}.crwebloc" && idx=$((idx+1))
    possible[$idx]="$myUserDir/Applications/Chrome Apps/${label}.app" && idx=$((idx+1))
    possible[$idx]="$myUserDir/Applications/Chrome Apps/${label}.crwebloc" && idx=$((idx+1))
    possible[$idx]="$myUserDir/Applications/Chrome Apps/${label}.webloc" && idx=$((idx+1))
  fi

  if echo "$browser" | grep -q -E "(any|edge)"; then
    possible[$idx]="$myUserDir/Applications/Edge Apps/${label}.app" && idx=$((idx+1))
    possible[$idx]="$myUserDir/Applications/Edge Apps/${label}.webloc" && idx=$((idx+1))
  fi

  for poss in $possible; do
    if [ -e "$poss" ]; then
      if echo "$poss:e" | grep -q "webloc"; then
        testUrl=$(plist::webloc::url "$poss")
      elif echo "$poss:e" | grep -q "app"; then
        testUrl=$(plist::webapp::url "$poss/Contents/Info.plist")
      fi

      if [ -n "$testUrl" ] && [[ "$testUrl" == "$url" ]]; then
        echo "$poss" && return 0
      fi
    fi
  done

  return 1
}

plist::dock::add::url() {
  local index url file label bundle json

  index="$1"
  json="$2"
  url=$(tile::url "$json")
  label=$(tile::label "$json")
  browser=$(tile::browser "$json")
  app=$(_findUrlApp "$label" "$url" "$browser")
  if [ -n "$app" ]; then
    # Add As App
    json=$(json-obj-add "$json" "url" "$app")
    plist::dock::add::app "$index" "$json"
  else
    /usr/libexec/PlistBuddy -c "add ${section}:${index} dict " "$dock"
    /usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data dict" "$dock"
    /usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:label string ${label}" "$dock"
    /usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:url dict" "$dock"
    /usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:url:_CFURLString string ${url}" "$dock"
    /usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:url:_CFURLStringType integer 15" "$dock"
    /usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-type string url-tile" "$dock"
  fi
}

plist::dock::add::directory() {
  local index url file label bundle json
  local showI dispI sortI showS dispS sortS

  index="$1"
  json="$2"
  url=$(tile::url "$json")
  file="file://$(echo "$url" | sed 's# #%20#g')"
  label=$(tile::label "$json")
  sortS=$(tile::sort "$json")
  dispS=$(tile::display "$json")
  showS=$(tile::show "$json")
  sortI=$(folder::sort::toInt "$sortS")
  dispI=$(folder::display::toInt "$dispS")
  showI=$(folder::show::toInt "$showS")

  >&2 echo "doing this for $section:$index"
	/usr/libexec/PlistBuddy -c "add ${section}:${index} dict " "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data dict" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-data dict" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-data:_CFURLString string ${url}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-data:_CFURLStringType integer 0" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-label string ${label}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:file-type integer 2" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:preferreditemsize integer -1" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:arrangement integer ${sortI}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:displayas integer ${dispI}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-data:showas integer ${showI}" "$dock"
	/usr/libexec/PlistBuddy -c "add ${section}:${index}:tile-type string directory-tile" "$dock"
}

plist::dock::empty() {
  local firstLabel
  firstLabel=$(/usr/libexec/PlistBuddy -c "print :${section}:0:tile-data" "$dock" 2>&1 | grep -v "Does Not Exist")
	if [ -n "$firstLabel" ]; then
		/usr/libexec/PlistBuddy -c "delete :${section}" "$dock"
		sleep 2
		firstLabel=$(/usr/libexec/PlistBuddy -c "print :${section}:0:tile-data" "$dock" 2>&1 | grep -v "Does Not Exist")
		if [ -n "$firstLabel" ]; then
		  exit 1
		fi
		/usr/libexec/PlistBuddy -c "add :${section} array" "$dock"
	fi
}

## endregion ################################### End Plist Functions

## region ###################################### Tile Create Functions

function tile::create::app() {
  local label posix app bundle

  bundle=$(plist::tile::data "bundle-identifier")
  posix=$(plist::tile::file)
  app=$(app::summarize "$posix")
  label=$(plist::tile::label)

  json-obj-add "{}" url "$app" label "$label" "bundle-identifier" "$bundle" type "app-tile"
}

function tile::create::directory() {
  local file label showI dispI sortI showS dispS sortS

  dispI=$(plist::tile::data displayas)
  showI=$(plist::tile::data showas)
  sortI=$(plist::tile::data arrangement)
  dispS=$(folder::display::toString "$dispI")
  showS=$(folder::show::toString "$showI")
  sortS=$(folder::sort::toString "$sortS")

  file=$(plist::tile::file)
  label=$(plist::tile::label)

  json-obj-add "{}" url "$file" label "$label" type "directory-tile" display "$dispS" sort "$sortS" show "$showS"
}

function tile::create::file() {
  local file label

  file=$(plist::tile::file)
  label=$(plist::tile::label)

  json-obj-add "{}" url "$file" label "$label" type "file-tile"
}

function tile::create::url() {
  local url label info brow

  if plist::tile::type | grep -q "file-tile"; then
    file=$(plist::tile::file)
    info="$file/Contents/Info.plist"
    if [ -f "$info" ]; then
      bundle=$(defaults read "$info" "CFBundleIdentifier" 2>/dev/null)
      if echo "$bundle" | grep -q "edgemac"; then
        brow="edge"
      elif echo "$bundle" | grep -q "chrome"; then
        brow="chrome"
      else
        brow="safari"
      fi
      url=$(plist::webapp::url "$info")
      label=$(plist::webapp::name "$info")
    elif echo "$file" | grep -qE ".crwebloc$"; then
      brow="chrome"
      url=$(plist::webloc::url "$file")
      label=$(plist::webloc::name "$file")
    elif echo "$file" | grep -qE ".webloc$"; then
      brow="any"
      url=$(plist::webloc::url "$file")
      label=$(plist::webloc::name "$file")
    else
      return 1
    fi
  else
    brow="any"
    url=$(plist::tile::url)
    label=$(plist::tile::label)
  fi

  json-obj-add "{}" url "$url" label "$label" type "url-tile" browser "$brow"
}

tile::resolve::app() {
  local app label bundle

  app="$1"
  bundle=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
  label=$(defaults read "$app/Contents/Info.plist" CFBundleDisplayName 2>/dev/null)
  [ -z "$label" ] && label=$(basename "$app" | sed 's/.app$//' )
  [ -z "$bundle" ] && return 1



  json-obj-add "{}" url "$app" label "$label" "bundle-identifier" "$bundle" type "app-tile"
}

tile::resolve() {
  if [[ "${1:0:1}" != "{" ]]; then
    if [[ "${1:0:4}" == "http" ]]; then
      # URL
      json-obj-add "{}" url "$url" label "$label" type "url-tile" browser "any"
    elif [ -d "$1" ]; then
      # Directory
      json-obj-add "{}" url "$file" label "$label" type "directory-tile" display "stack" sort "name" show "auto"
    else
      # App or File
      appPath=$(app::resolve "$1")
      if [ -n "$appPath" ]; then
        # App
        tile::resolve::app "$appPath"
      elif [ -f "$1" ]; then
        # File
        json-obj-add "{}" url "$file" label "$label" type "file-tile"
      fi
    fi
  else
    # Already a JSON Object
    echo "$1"
  fi
}

## endregion ################################### Tile Creation Functions

## region ###################################### Tile Object Functions

tile::url() {
  jq -r '.url' <<< "$1"
}

tile::label() {
  jq -r '.label' <<< "$1"
}

tile::bundle() {
  jq -r '."bundle-identifier"' <<< "$1"
}

tile::display() {
  jq -r '.display' <<< "$1"
}

tile::sort() {
  jq -r '.sort' <<< "$1"
}

tile::show() {
  jq -r '.show' <<< "$1"
}

tile::browser() {
  jq -r '.browser' <<< "$1"
}

tile::type() {
  jq -r '.type' <<< "$1"
}

## endregion ################################### Tile Object Functions

## region ###################################### Dock Creation Functions

function dock::tile::create() {
  local type json

  section="$1"
  position="$2"

  type=$(plist::tile::type)
  if [ -n "$type" ]; then
    if [[ "$type" == "file-tile" ]]; then
      file=$(plist::tile::file)
      if posix::is::url "$file"; then
        json="$(tile::create::url)"
      elif posix::is::app "$file"; then
        json=$(tile::create::app)
      else
        json=$(tile::create::file)
      fi
    elif [[ "$type" == "directory-tile" ]]; then
      json=$(tile::create::directory)
    elif [[ "$type" == "url-tile" ]]; then
      json=$(tile::create::url)
    else
      json="{}"
    fi

    if [[ "$MACDOCK_FORMAT" == "yaml" ]]; then
      yq -P <<< "$json"
    else
      echo "$json"
    fi

    return 0
  else
    return 1
  fi
}

function is-special() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | grep -q "$1"
}

function dock::create() {
  local tile tiles x jsonArr tSection sections jsonObj

  dock="$1"
  jsonObj="{}"
  declare -a sections
  sections[1]="persistent-apps"
  sections[2]="persistent-others"

  for tSection in $sections; do
    tiles=()
    tile="{}"
    x=0
    while [[ -n "$tile" ]]; do
      tile=$(dock::tile::create "$tSection" "$x")
      if [ -n "$tile" ]; then
        tiles+=("$tile")
      fi
      x=$((x+1))
    done

    jsonArr="[]"
    for tile in $tiles; do
      if jq -r '.type' <<< "$tile" | grep -q "app-tile"; then
        url=$(tile::url "$tile")
        label=$(tile::label "$tile")
        if is-special "$url"; then
          jsonArr=$(json-arr-add "$jsonArr" "$url")
        elif [[ "$label" == "$url" ]]; then
          jsonArr=$(json-arr-add "$jsonArr" "$url")
        elif [[ "$(echo "$url" | sed "s#~/Applications/##" | sed -E "s#.app##")" == "$label" ]]; then
          jsonArr=$(json-arr-add "$jsonArr" "$url")
        else
          jsonArr=$(json-arr-add "$jsonArr" "$tile")
        fi
      else
        jsonArr=$(json-arr-add "$jsonArr" "$tile")
      fi
    done
    jsonObj=$(json-obj-add "$jsonObj" "$tSection" "$jsonArr")
  done

  echo "$jsonObj"
}

function dock::import() {
  local dock jsonObj sections tSection x tile
  dock="$1"
  jsonObj="$2"
  declare -a sections
  sections[1]="persistent-apps"
  sections[2]="persistent-others"

  for tSection in $sections; do
    section="$tSection"
    echo "$section:"
    echo " Emptying Section..."
    plist::dock::empty
    tile="{}"
    x=0
    while [ -n "$tile" ]; do
      tile=$(jq -r ".\"${tSection}\"[${x}]//empty" <<< "$jsonObj")
      if [ -n "$tile" ]; then
        tile=$(tile::resolve "$tile")
        type=$(tile::type "$tile")
        case "$type" in
          app*)
            echo "  Adding App: $(tile::label "$tile")"
            plist::dock::add::app "$x" "$tile" ;;
          file*)
            echo "  Adding File: $(tile::label "$tile")"
            plist::dock::add::file "$x" "$tile" ;;
          directory*)
            echo "  Adding Directory: $(tile::label "$tile")"
            plist::dock::add::directory "$x" "$tile" ;;
          url*)
            echo "  Adding URL: $(tile::label "$tile")"
            plist::dock::add::url "$x" "$tile" ;;
        esac
      fi
      x=$((x+1))
    done
  done
}

## endregion ################################### Dock Functions

## region ###################################### User Functions

# @brief Shows the username of the current console user, if any is logged in.
# @noargs
# @stdout string The Username
function user::console() {
  echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }'
}

# @description Prints the POSIX path to the given user's home directory.
# @arg $1 string Username; defaults to $dockUser
# @stdout string The given user's home directory, if it can be discovered and exists
# @exitcode 0 User exists, their home directory can be found, and it exists.
# @exitcode 1 User does not exist OR home directory cannot be found OR directory does not exist.
function user::dir() {
  local suDir

  if [ -n "${1:-$dockUser}" ]; then
    if ! /usr/bin/id -u "$1" | /usr/bin/grep -q "no such user"; then
      # Primary information source
      suDir=$(/usr/bin/dscl . -read /Users/"${1:-$dockUser}" NFSHomeDirectory 2> /dev/null | /usr/bin/awk -F ': ' '{print $2}')
      # While this is not always correct, it is likely to be correct if the desktop directory exists, so good fallback.
      [ -z "$suDir" ] && suDir=$(find "/Users" -type d -name "Desktop" 2> /dev/null | grep "/Users/${1:-$dockUser}/Desktop")
      # Make the directory exists, and strip the "Desktop" portion if applicable
      [ -n "$suDir" ] && [ -d "$suDir" ] && echo "${suDir/\/Desktop/}" && return 0
    fi
  fi

  return 1
}

## endregion ################################### User Functions

## region ###################################### Input Handling

outFormat="text"
while [ "$1" != "" ]; do
  # Check for our added flags
  case "$1" in
      --json )                    outFormat="json";       ;;
      --yaml )                    outFormat="yaml"       ;;
      --user )                    myUser="$2";         shift ;;
      --out  )                    outFile="$2";          shift ;;
      --in   )                    inFile="$2";           shift ;;
      -h | --help )               output::usage;                            exit; ;; # quit and show usage
      --version )                 output::version;                          exit; ;; # quit and show usage
      * )                         file="$1"              # if no match, add it to the positional args
  esac
  shift # move to next kv pair
done

# Resolve User
if [ -z "$myUser" ]; then
  if [ -n "$jamfUser" ]; then
    myUser="$jamfUser"
  elif [ -n "$USER" ] && [[ "$USER" != "root" ]]; then
    myUser="$USER"
  fi
fi

# Set User Plist
if [ -n "$myUser" ]; then
 myUserDir=$(user::dir "$myUser")
 plistUser="$myUserDir/$plistDir/$plistFile"
fi

# Handle Input/Output
if [ -n "$inFile" ]; then
  if [ -z "$outFile" ]; then
    if [ -n "$file" ]; then
      outFile="$file"
    else
      outFile="$plistUser"
    fi
  fi

elif [ -n "$outFile" ]; then

  if [ -z "$inFile" ]; then
    if [ -n "$file" ]; then
      inFile="$file"
    else
      inFile="$plistUser"
    fi
  fi

else
  outFile="/dev/stdout"
  if [ -n "$file" ]; then
    inFile="$file"
  else
    inFile="$plistUser"
  fi

fi

## endregion ################################### Input Handling

## region ###################################### Main Code

if [[ "$inFile:e" == "plist" ]]; then
  [ -z "$outFormat" ] && outFormat="text"
  case "$outFormat" in
    yaml)
      dock::create "$inFile" | yq -P > "$outFile" ;;
    json)
      if [[ "$outFile" == "/dev/stdout" ]]; then
        jq <<< $(dock::create "$inFile")
      else
        dock::create "$inFile" > "$outFile"
      fi
      ;;
    *)
  esac
elif [ -n "$outFile" ] && [[ "$outFile:e" == "plist" ]]; then
  [ -z "$outFormat" ] && outFormat="plist"
  if [ -n "$inFile" ]; then
     if [[ "$inFile:e" == "plist" ]]; then
       # Just Copy It
       cp "$inFile" "$outFile"
     else
       if [[ "$inFile:e" == "yaml" ]]; then
         json=$(yq eval "$inFile" -o=json -P)
       elif [[ "$inFile:e" == "json" ]]; then
         json=$(cat "$inFile")
       fi
       dock::import "$outFile" "$json"
       if [[ "$(user::console)" == "$myUser" ]]; then
         killall cfprefsd && killall Dock
       fi
     fi
  fi
fi

## endregion ################################### End Main Code