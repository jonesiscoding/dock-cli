#!/bin/zsh

myName="dock-cli"
myDest="/usr/local/sbin"
myRepo="jonesiscoding/dock-cli"

## region ############################################## Destination

# Allow setting of destination via prefix, verify that it's writable
[ -n "$1" ] && myDest="$1"
[ ! -w "myDest" ] && echo "Destination directory '$myDest' is not writable by this user." && exit 1

## endregion ########################################### End Destination

## region ############################################## Main Code

installed=""
if [ -f "$myDest/${myName}" ]; then
  installed="$("$myDest/$myName" --version | /usr/bin/awk '{ print $2 }')"
fi

repoUrl="https://github.com/${myRepo}/releases/latest"
effectiveUrl=$(curl -Ls -o /dev/null -I -w '%{url_effective}' "$repoUrl")
tag=$(echo "$effectiveUrl" | /usr/bin/rev | /usr/bin/cut -d'/' -f1 | /usr/bin/rev)
[[ "$tag" == "releases" ]] && tag="v1.0"
if [ -n "$tag" ]; then
  # Exit successfully if same version
  [[ "$tag" == "$installed" ]] && exit 0
  dlUrl="https://github.com/${myRepo}/archive/refs/tags/${tag}.zip"
  repoFile=$(/usr/bin/basename "$dlUrl")
  tmpDir="/private/tmp/${myName}/${tag}"
  [ -d "$tmpDir" ] && /bin/rm -R "$tmpDir"
  if /bin/mkdir -p "$tmpDir"; then
    if /usr/bin/curl -Ls -o "$tmpDir/$repoFile" "$dlUrl"; then
      cd "$tmpDir" || exit 1
      if /usr/bin/unzip -qq "$tmpDir/$repoFile"; then
        /bin/rm "$tmpDir/$repoFile"
        if /bin/cp "$tmpDir/${myName}-${tag//v/}/src/${myName}" "$myDest/"; then
          /bin/chmod 755 "$myDest/$myName"
          /bin/rm -R "$tmpDir"
          # Success - Exit Gracefully
          exit 0
        fi
      fi
    fi
  fi
fi

# All Paths that lead here indicate we couldn't install
exit 1

## endregion ########################################### End Main Code