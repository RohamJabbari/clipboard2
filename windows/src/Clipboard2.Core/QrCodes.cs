using ZXing;
using ZXing.Common;
using ZXing.QrCode;

namespace Clipboard2.Core;

/// <summary>QR codes with ZXing.Net: finding an otpauth link in a copied image, and drawing one for Show Secret / QR.</summary>
public static class QrCodes
{
    /// <summary>The text of a QR code in a BGRA32 image, or null.</summary>
    public static string? Decode(byte[] bgra, int width, int height)
    {
        if (width <= 0 || height <= 0 || bgra.Length < width * height * 4) return null;
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions { PossibleFormats = [BarcodeFormat.QR_CODE], TryHarder = true },
        };
        try
        {
            return reader.Decode(new RGBLuminanceSource(bgra, width, height, RGBLuminanceSource.BitmapFormat.BGRA32))?.Text;
        }
        catch (Exception ex) when (ex is ArgumentException or IndexOutOfRangeException or ReaderException)
        {
            return null;
        }
    }

    /// <summary>The otpauth link a captured image shows as a QR code, or null.</summary>
    public static string? FindOtpAuth(byte[] bgra, int width, int height) =>
        Decode(bgra, width, height) is { } text && OtpAuthUri.IsOtpAuth(text) ? text.Trim() : null;

    /// <summary>The modules of a QR code for <paramref name="text"/> (true = dark), including a 2-module quiet zone.</summary>
    public static bool[,] Encode(string text)
    {
        var matrix = new QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0,
            new Dictionary<EncodeHintType, object> { [EncodeHintType.MARGIN] = 2, [EncodeHintType.ERROR_CORRECTION] = ZXing.QrCode.Internal.ErrorCorrectionLevel.M });
        var result = new bool[matrix.Width, matrix.Height];
        for (var x = 0; x < matrix.Width; x++)
            for (var y = 0; y < matrix.Height; y++)
                result[x, y] = matrix[x, y];
        return result;
    }

    /// <summary>Draws <see cref="Encode"/>'s modules as a BGRA32 image, <paramref name="scale"/> pixels per module.</summary>
    public static (byte[] Bgra, int Width, int Height) Render(string text, int scale = 6)
    {
        var modules = Encode(text);
        int w = modules.GetLength(0) * scale, h = modules.GetLength(1) * scale;
        var pixels = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var v = modules[x / scale, y / scale] ? (byte)0 : (byte)255;
                var i = (y * w + x) * 4;
                pixels[i] = pixels[i + 1] = pixels[i + 2] = v;
                pixels[i + 3] = 255;
            }
        return (pixels, w, h);
    }
}
