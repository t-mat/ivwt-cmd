ivwt-cmd
========

A lightweight CLI image viewer for Windows Terminal (single batch file).


Example
-------

```
cmd.exe
pushd %PUBLIC%

mkdir ivwt-test
cd    ivwt-test
curl.exe -LOJ https://github.com/t-mat/ivwt-cmd/archive/refs/heads/main.zip
tar.exe xvf ivwt-cmd-main.zip
cd          ivwt-cmd-main

.\ivwt.cmd .\assets\sunrise.jpg

curl.exe -LOJ https://upload.wikimedia.org/wikipedia/en/c/cb/This_is_fine_from_On_Fire_strip_by_KC_Green.jpg
.\ivwt.cmd .\This_is_fine_from_On_Fire_strip_by_KC_Green.jpg
```


Install
-------

Place `ivwt.cmd` in a directory included in your `%PATH%`.


Usage
-----

```
ivwt.cmd <image-file-path>
```


Code overview
-------------

`ivwt` uses [WIC](https://en.wikipedia.org/wiki/Windows_Imaging_Component) to decode images.
After decoding, it converts RGB data to [Sixel](https://en.wikipedia.org/wiki/Sixel) sequences, allowing images to be displayed [directly in Windows Terminal](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-22-release/).


Build
-----

```
pwsh.exe .\scripts\build.ps1
```


Credits
-------

This project uses the following image asset:

- `assets/sunrise.jpg`: Photo by [Othmar Ortner](https://unsplash.com/@oortnerphoto) on [Unsplash](https://unsplash.com/photos/landscape-photography-of-mountains-qy8l3MUSl4Y).

The image is used under the [Unsplash License](https://unsplash.com/license).
