@setlocal & set "s=%~f0" & set "a=%*" & pwsh -nop -ep Bypass -c "Add-Type -Ty ((gc $env:s -raw)-split'//CS_BEGIN')[2]; exit [P]::Entry($env:a);" & exit /b %ERRORLEVEL%

//CS_BEGIN
// Everything below this line is C# code.
// Image viewer for windows terminal.
//
// SPDX-FileCopyrightText: Copyright (c) Takayuki Matsuoka
// SPDX-License-Identifier: MIT-0
//

// ReSharper disable CheckNamespace
// ReSharper disable RedundantNullableDirective
// ReSharper disable RedundantUsingDirective

#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

#pragma warning disable CA1050
#pragma warning disable SYSLIB1054

// ReSharper disable once UnusedType.Global
public static class P {
    // ReSharper disable once UnusedMember.Global
    public static int Entry(string raw) => Program.Main(SplitWindowsArgs(raw));

    private static string[] SplitWindowsArgs(string cmdline)
    {
        if (string.IsNullOrEmpty(cmdline)) {
            return Array.Empty<string>();
        }
        IntPtr argvPtr = CommandLineToArgvW(cmdline, out int argc);
        if (argvPtr == IntPtr.Zero) {
            return new[] { cmdline };
        }

        try {
            var args = new string[argc];
            for (int i = 0; i < argc; i++) {
                args[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argvPtr, i * IntPtr.Size)) ?? string.Empty;
            }
            return args;
        }
        finally {
            LocalFree(argvPtr);
        }
    }

    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr hMem);
}

public static class Program {
    public static int Main(string[] args)
    {
        if (args.Length == 0 || ! File.Exists(args[0])) {
            Console.WriteLine($"{Path.GetFileNameWithoutExtension(Environment.ProcessPath)} <image-file-path>");
            return 1;
        }

        try {
            (int width, int height, byte[] bgraPixels)           = Wic.LoadImage(Path.GetFullPath(args[0]));
            (byte[] indices, (byte r, byte g, byte b)[] palette) = MedianCutQuantizer.Quantize(bgraPixels, width, height);

            int maxSixelLen = SixelConverter.GetMaxSixelLength(width, height);
            var sixelBuffer = new char[maxSixelLen];

            ReadOnlySpan<char> result = SixelConverter.ConvertToSixel(
                width,
                height,
                indices,
                palette.Length,
                palette,
                sixelBuffer
            );

            if (result.IsEmpty) {
                throw new Exception("Failed to write sixel data.");
            }

            using Stream stdout     = Console.OpenStandardOutput();
            var          byteBuffer = new byte[result.Length];
            int          count      = Encoding.ASCII.GetBytes(result, byteBuffer);
            stdout.Write(byteBuffer, 0, count);
            stdout.Flush();
        }
        catch (Exception ex) {
            Console.Error.WriteLine($"Error: {ex.Message}");
            return 1;
        }
        return 0;
    }
}

internal static class SixelConverter {
    public static int GetMaxSixelLength(int width, int height)
    {
        int       perColorLine = 5 + width * 2 + 1;
        const int maxColors    = 255;
        int       perBand      = maxColors * perColorLine + 1;
        int       bands        = (height + 5) / 6;
        return 100 + 20 * maxColors + bands * perBand + 100;
    }

    public static ReadOnlySpan<char> ConvertToSixel(int width, int height, ReadOnlySpan<byte> indexColorPixels,
        int paletteCount, ReadOnlySpan<(byte r, byte g, byte b)> paletteColors, Span<char> dstBuffer)
    {
        int pos = 0;

        // Header
        Append(dstBuffer, ref pos, $"\u001bPq\"1;1;{width};{height}");

        // Palette
        for (int i = 0; i < paletteCount; i++) {
            (byte r, byte g, byte b) = paletteColors[i];
            Append(dstBuffer, ref pos, $"#{i};2;{r * 100 / 255};{g * 100 / 255};{b * 100 / 255}");
        }

        // Data
        for (int y = 0; y < height; y += 6) {
            for (int colorIdx = 0; colorIdx < paletteCount; colorIdx++) {
                int savedPos = pos;
                AppendChar(dstBuffer, ref pos, '#');
                AppendInt(dstBuffer, ref pos, colorIdx);

                bool anyPixelFound = false;
                char lastChar      = '\0';
                int  repeatCount   = 0;

                for (int x = 0; x < width; x++) {
                    int sixelVal = 0;
                    for (int i = 0; i < 6; i++) {
                        int cy = y + i;
                        if (cy < height && indexColorPixels[cy * width + x] == colorIdx) {
                            sixelVal |= 1 << i;
                        }
                    }
                    if (sixelVal != 0) {
                        anyPixelFound = true;
                    }

                    var c = (char)(63 + sixelVal);
                    if (c == lastChar) {
                        repeatCount++;
                    } else {
                        FlushLine(dstBuffer, ref pos, repeatCount, lastChar);
                        lastChar    = c;
                        repeatCount = 1;
                    }
                }
                FlushLine(dstBuffer, ref pos, repeatCount, lastChar);

                if (anyPixelFound) {
                    AppendChar(dstBuffer, ref pos, '$');
                } else {
                    pos = savedPos;
                }
            }
            AppendChar(dstBuffer, ref pos, '-');
        }

        Append(dstBuffer, ref pos, "\u001b\\\n");
        return dstBuffer[..pos];

        static void FlushLine(Span<char> span, ref int pos, int count, char c)
        {
            if (count > 1) {
                AppendChar(span, ref pos, '!');
                AppendInt(span, ref pos, count);
            }
            if (count > 0) {
                AppendChar(span, ref pos, c);
            }
        }

        static void Append(Span<char> span, ref int pos, string s)
        {
            foreach (char c in s) {
                span[pos++] = c;
            }
        }

        static void AppendChar(Span<char> span, ref int pos, char c) => span[pos++] = c;

        static void AppendInt(Span<char> span, ref int pos, int val)
        {
            val.TryFormat(span[pos..], out int written);
            pos += written;
        }
    }
}

internal static class MedianCutQuantizer {
    public static (byte[] indices, (byte r, byte g, byte b)[] palette) Quantize(byte[] bgraPixels, int width, int height,
        int maxColors = 256)
    {
        int pixelCount = width * height;
        var colorArray = new (byte r, byte g, byte b)[pixelCount];

        for (int i = 0, j = 0; i < pixelCount; i++, j += 4) {
            colorArray[i] = (bgraPixels[j + 2], bgraPixels[j + 1], bgraPixels[j]);
        }

        List<ColorBox> boxes = new() { new ColorBox(colorArray, 0, pixelCount) };
        while (boxes.Count < maxColors) {
            int splitIdx = -1, maxVol = -1;
            for (int i = 0; i < boxes.Count; i++) {
                if (boxes[i].Count >= 2 && boxes[i].Volume > maxVol) {
                    maxVol   = boxes[i].Volume;
                    splitIdx = i;
                }
            }
            if (splitIdx == -1) {
                break;
            }

            (ColorBox b1, ColorBox b2) = boxes[splitIdx].Split();
            boxes[splitIdx]            = b1;
            boxes.Add(b2);
        }

        var palette = new (byte r, byte g, byte b)[boxes.Count];
        for (int i = 0; i < boxes.Count; i++) {
            palette[i] = boxes[i].GetAverageColor();
        }

        var resultIndices = new byte[pixelCount];
        Parallel.For(
            0,
            height,
            y =>
            {
                int offset = y * width;
                for (int x = 0; x < width; x++) {
                    int i = offset + x;
                    int j = i * 4;

                    (byte r, byte g, byte b) p = (r: bgraPixels[j + 2], g: bgraPixels[j + 1], b: bgraPixels[j]);

                    int bestIdx = 0;
                    int minDist = int.MaxValue;
                    for (int k = 0; k < palette.Length; k++) {
                        int dr = p.r - palette[k].r;
                        int dg = p.g - palette[k].g;
                        int db = p.b - palette[k].b;
                        //
                        int d = dr * dr + dg * dg + db * db;
                        if (d < minDist) {
                            minDist = d;
                            bestIdx = k;
                            if (d == 0) {
                                break;
                            }
                        }
                    }
                    resultIndices[i] = (byte)bestIdx;
                }
            }
        );

        return (resultIndices, palette);
    }

    private readonly struct ColorBox {
        private readonly (byte r, byte g, byte b)[] _src;
        private int Start { get; }
        public int Count { get; }
        private readonly byte _rMin, _rMax, _gMin, _gMax, _bMin, _bMax;

        public ColorBox((byte r, byte g, byte b)[] src, int start, int count)
        {
            _src  = src;
            Start = start;
            Count = count;
            _rMin = _gMin = _bMin = 255;
            _rMax = _gMax = _bMax = 0;
            for (int i = start; i < start + count; i++) {
                var c = src[i];
                if (c.r < _rMin) {
                    _rMin = c.r;
                }
                if (c.r > _rMax) {
                    _rMax = c.r;
                }
                if (c.g < _gMin) {
                    _gMin = c.g;
                }
                if (c.g > _gMax) {
                    _gMax = c.g;
                }
                if (c.b < _bMin) {
                    _bMin = c.b;
                }
                if (c.b > _bMax) {
                    _bMax = c.b;
                }
            }
        }

        public int Volume => Math.Max(_rMax - _rMin, Math.Max(_gMax - _gMin, _bMax - _bMin));

        public (ColorBox, ColorBox) Split()
        {
            int axis = _rMax - _rMin >= _gMax - _gMin && _rMax - _rMin >= _bMax - _bMin ? 0 :
                _gMax - _gMin >= _bMax - _bMin ? 1 : 2;
            Array.Sort(
                _src,
                Start,
                Count,
                Comparer<(byte r, byte g, byte b)>.Create((x, y) =>
                    axis switch { 0 => x.r - y.r, 1 => x.g - y.g, _ => x.b - y.b }
                )
            );
            int mid = Count / 2;
            return (new ColorBox(_src, Start, mid), new ColorBox(_src, Start + mid, Count - mid));
        }

        public (byte, byte, byte) GetAverageColor()
        {
            long sr = 0;
            long sg = 0;
            long sb = 0;
            for (int i = Start; i < Start + Count; i++) {
                sr += _src[i].r;
                sg += _src[i].g;
                sb += _src[i].b;
            }
            return ((byte)(sr / Count), (byte)(sg / Count), (byte)(sb / Count));
        }
    }
}

internal static class Wic {
    // ReSharper disable InconsistentNaming
    private static readonly Guid CLSID_WICImagingFactory      = new("317d06e8-5f24-433d-bdf7-79ce68d8abc2");
    private static readonly Guid GUID_WICPixelFormat32bppBGRA = new("6fddc324-4e03-4bfe-b185-3d77768dc90f");
    private const           uint GENERIC_READ                 = 0x80000000;
    // ReSharper restore InconsistentNaming

    public static (int width, int height, byte[] pixels) LoadImage(string filePath)
    {
        IWICImagingFactory?    factory   = null;
        IWICBitmapDecoder?     decoder   = null;
        IWICBitmapFrameDecode? frame     = null;
        IWICFormatConverter?   converter = null;

        try {
            Type factoryType = Type.GetTypeFromCLSID(CLSID_WICImagingFactory) ?? throw new Exception("WIC not available");
            factory = (IWICImagingFactory?)Activator.CreateInstance(factoryType)
                      ?? throw new Exception("Failed to create WIC Factory");

            try {
                factory.CreateDecoderFromFilename(
                    wzFilename: filePath,
                    pguidVendor: IntPtr.Zero,
                    dwDesiredAccess: unchecked((int)GENERIC_READ),
                    metadataOptions: 0,
                    ppIDecoder: out decoder
                );
            }
            catch (COMException ex) {
                throw (uint)ex.ErrorCode switch
                {
                    0x88982F50 => new InvalidOperationException("Unknown format/Bad Header", ex),
                    0x88982F60 => new InvalidOperationException("Bad Image",                 ex),
                    0x88982F61 => new InvalidOperationException("Bad Header",                ex),
                    _ => ex
                };
            }

            if (decoder == null) {
                throw new Exception("Failed to create Decoder");
            }
            decoder.GetFrame(0, out frame);
            if (frame == null) {
                throw new Exception("Failed to get Frame");
            }

            frame.GetSize(out uint w, out uint h);
            factory.CreateFormatConverter(out converter);
            if (converter == null) {
                throw new Exception("Failed to create Converter");
            }

            Guid   targetFormat = GUID_WICPixelFormat32bppBGRA;
            IntPtr pFrame       = Marshal.GetComInterfaceForObject(frame, typeof(IWICBitmapSource));
            try {
                converter.Initialize(pFrame, ref targetFormat, 0, IntPtr.Zero, 0.0, 0);
            }
            catch (COMException ex) {
                throw new InvalidOperationException("Pixel format conversion failed.", ex);
            }
            finally {
                if (pFrame != IntPtr.Zero) {
                    Marshal.Release(pFrame);
                }
            }

            uint stride     = w * 4;
            var  bgraPixels = new byte[stride * h];
            converter.CopyPixels(
                prc: IntPtr.Zero,
                cbStride: stride,
                cbBufferSize: (uint)bgraPixels.Length,
                pbBuffer: Marshal.UnsafeAddrOfPinnedArrayElement(bgraPixels, 0)
            );

            return ((int)w, (int)h, bgraPixels);
        }
        finally {
            if (converter != null) {
                Marshal.ReleaseComObject(converter);
            }
            if (frame != null) {
                Marshal.ReleaseComObject(frame);
            }
            if (decoder != null) {
                Marshal.ReleaseComObject(decoder);
            }
            if (factory != null) {
                Marshal.ReleaseComObject(factory);
            }
        }
    }

    [ComImport, Guid("00000301-a8f2-4877-ba0a-fd2b6645fb94"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWICFormatConverter : IWICBitmapSource {
        // ReSharper disable UnusedMember.Global
        void _Stub0();
        void _Stub1();
        void _Stub2();
        void _Stub3();
        // ReSharper restore UnusedMember.Global

        void CopyPixels(IntPtr prc, uint cbStride, uint cbBufferSize, IntPtr pbBuffer);

        void Initialize(IntPtr pISource, [In] ref Guid dstFormat, int dither, IntPtr pIPalette,
            double alphaThresholdPercent, int paletteTranslate);
    }

    [ComImport, Guid("ec5ec8a9-c395-4314-9c77-54d7a935ff70"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWICImagingFactory {
        void CreateDecoderFromFilename([MarshalAs(UnmanagedType.LPWStr)] string wzFilename, IntPtr pguidVendor,
            int dwDesiredAccess, int metadataOptions, out IWICBitmapDecoder ppIDecoder);

        // ReSharper disable UnusedMember.Global
        void _Stub1();
        void _Stub2();
        void _Stub3();
        void _Stub4();
        void _Stub5();
        void _Stub6();
        // ReSharper restore UnusedMember.Global

        void CreateFormatConverter(out IWICFormatConverter ppIFormatConverter);
    }

    [ComImport, Guid("9EDDE9E7-8DEE-47ea-99DF-E6FAF2ED44BF"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWICBitmapDecoder {
        // ReSharper disable UnusedMember.Global
        void _Stub0();
        void _Stub1();
        void _Stub2();
        void _Stub3();
        void _Stub4();
        void _Stub5();
        void _Stub6();
        void _Stub7();
        void _Stub8();
        void _Stub9();
        // ReSharper restore UnusedMember.Global

        void GetFrame(uint index, out IWICBitmapFrameDecode ppIBitmapFrame);
    }

    [ComImport, Guid("3B16811B-6A43-4ec9-A813-3D930C13B940"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWICBitmapFrameDecode : IWICBitmapSource {
        void GetSize(out uint puiWidth, out uint puiHeight);
    }

    [ComImport, Guid("00000120-a8f2-4877-ba0a-fd2b6645fb94"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWICBitmapSource {
    }
}
