# Dock CLI

A shell utility to allow for import of a macOS dock from data in Yaml, JSON, XML Plist, or Configuration Profile, as
well as the export of user docks to a simple Yaml, JSON, or simple XML Plist format.

## Exporting

Exporting allows for a simple configuration file to be generated, which has a number of useful applications, including:

* Backup of a user's Dock for later restoration
* Creating an initial dock configuration for a specific department or role
* Inspecting the shortcuts in a dock for troubleshooting purposes.

You can export the dock of the current user, or using `sudo` and the `--user` flag, the dock of a different user.  The
output format can be specified with `--json | yaml | prefs` flags. By default, results are shown via _stdout_ unless
the `--out` flag is specified with an output file.

## Importing

Importing allows for a simple configuration to be used to specify the shortcuts on a user's dock.  You can import from
a YAML, JSON, or (simplified) XML Plist file, or directly from a Configuration Profile or XML Plist file in the system
or user preferences.

The file to import from can be specified with the `--in <path>` flag, or the `--managed` or `--prefs` flags can be used
to import from a Configuration Profiles, System Preferences, or User Preferences.

After an import, if the applicable user is currently logged in, the Dock is service is restarted.  To bypass this 
behavior, the `--no-restart` flag can be used. 

## Configuration via JAMF

To use a Configuration Profile with the JAMF _Application & Custom Settings_ payload, use the `--schema` flag to output
the schema, which will be preconfigured with your bundle prefix.

## Configuration via Configuration Profile

To use a manually installed Configuration Profile or another MDM solution that supports configuration profiles, use the
`--mobileconfig` to output a preconfigured Configuration Profile based on a user's dock. By default, your own dock is
used, otherwise `sudo` and the `--user` flag may be used to source the profile from a specific user's dock.

If you prefer to use a YAML, JSON, or XML Plist file for the source of the `.mobileconfig`, this can be specified using
the `--in <path>` flag.

## Configuration via Preferences

Configuration via a plist preference file may seem redundant, however the XML Plist used is greatly simplified when
compared to Apple's `com.apple.dock.plist` files. To see an easy example, use `dock --prefs --out <file>` to export
your own dock.

Once created, your plist can be located in `/Library/Preferences` for system-wide preferences, or`~/Library/Preferences`
for user-specific preferences.  These preference files can then be imported with `sudo dock --user <user> --prefs`.

## Generating or Writing Configuration Files

One of the easiest ways to generate a configuration file in your desired format is to do an export on an existing dock.
For instance, you could create a temporary user on any macOS system, configure the dock in the UI, then run 
`dock --user <username> --<format> --out <export_path>` to generate the configuration file.

Alternatively, configuration files can be written by hand.  Regardless of the format the important keys are:

* `persistent-apps`
* `persistent-others`

Application shortcuts are specified just using the name of the application, derived from the filename.  For instance,
`/Applications/Google Chrome.app` would be specified as 'Google Chrome'.

Applications in user-space are specified as `~/Applications/Google Chrome.app`.

### Special Apps

There are some apps that can vary in name or installation path over time, or by role within an organization. Examples
include "yearly" Adobe apps, Adobe Acrobat, or apps that have a different name for a free vs. pro version.

#### Yearly Adobe Apps

Rather than specifying _Adobe Photoshop 2025_ in a configuration, you can specify `photoshop` to always create a
shortcut to the most recent version of Adobe Photoshop installed. To configure a shortcut for a specific year, you can
specify by adding the year to the slug, such as: `photoshop-2024`.  

If a year is specified and the app with that year is not installed **dock-cli** will use the next oldest version
available, as far back as 2014. If no app is found, the shortcut is omitted.

#### Adobe Acrobat

The slug `acrobat` can be used to specify Acrobat. If installed, the following apps will be used for the shortcut, in
order of priority: Acrobat Pro, Acrobat Reader, Preview.

### File Shortcuts

File shortcuts can be specified simply by giving the absolute path to the file. Alternatively, a `url` (posix path) and 
`label` (My Label) keys can be specified in the entry for additional control.

### URL Shortcuts

URL can be specified with just the URL, or as an entry with the following keys: 

* `url` (https://myorganizationwebsitedomainthing.com)
* `label` (My Label)
* `browser` (chrome, safari, edge, any)

The `browser` key is used to locate webapps in `~/Applications`, `~/Applications/Chrome Apps`, or 
`~/Applications/Edge Apps`. Standard application locations are also checked for matching `.webloc` files. If one of
these files with a matching URL is found, it is used instead of a simple dock shortcut.

### Directory Shortcuts

Directory shortcuts can be specified simply by giving the absolute path to the directory.  Alternatively, an entry with
the following keys can be used:

* `url` (posix path)
* `label` (My Label)
* `display` (`folder`, `stack`)
* `sort` (`kind`, `datecreated`, `datemodified`, `dateadded`, `name`)
* `show` (`list`, `grid`, `fan`, `auto`)

## Bundle Prefix

For configuration via Configuration Profile or Preferences, a specific bundle prefix is used.  As this app is designed
to be used in a managed environment, the bundle prefix is not specific to this app, but the environment.

You can see the detected bundle name with the `--bundle` flag.

The prefix will be automatically generated using the following, in order of precedence:

* Directly from the `--prefix <prefix>` flag.
* Directly from the `$MDM_BUNDLE_PREFIX` environment variable.
* Reverse DNS notation, sourced from the domain of the system's hostname, if a fqdn is used. (macbook4.yourname.org => org.yourname)
* Reverse DNS notation, sourced from the configured JAMF JSS_URL (yourname.jamfcloud.com => com.jamfcloud.yourname)
* Literally `org.yourname` as a fallback, if all of the above fail.

The full bundle name then becomes `com.prefix.dock`.
