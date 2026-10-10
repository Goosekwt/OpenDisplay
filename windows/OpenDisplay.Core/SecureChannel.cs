using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace OpenDisplay.Core;

public sealed class SecureChannel : IDisposable
{
    public const int MaxRecord = 8_388_633;
    private readonly Stream stream;
    private readonly AesGcm sendCipher, receiveCipher;
    private readonly SemaphoreSlim writer = new(1);
    private ulong sendSequence, receiveSequence;
    private int disposed;
    private SecureChannel(Stream stream, byte[] sendKey, byte[] receiveKey)
    {
        this.stream = stream;
        sendCipher = new(sendKey, 16); receiveCipher = new(receiveKey, 16);
        CryptographicOperations.ZeroMemory(sendKey); CryptographicOperations.ZeroMemory(receiveKey);
    }

    public static async Task<SecureChannel> ConnectAsync(Stream stream, byte[] pairingKey, CancellationToken ct)
    {
        if (pairingKey.Length != 32) throw new ArgumentException("Pairing key must be 32 bytes.");
        var c = RandomNumberGenerator.GetBytes(32);
        await stream.WriteAsync(Join("OPD1"u8.ToArray(), c), ct);
        var reply = new byte[68]; await stream.ReadExactlyAsync(reply, ct);
        if (!reply.AsSpan(0, 4).SequenceEqual("OPA1"u8)) throw new IOException("Not an OpenDisplay receiver.");
        var s = reply[4..36]; var salt = Join(c, s);
        var proof = HMACSHA256.HashData(pairingKey, Join("server"u8.ToArray(), salt));
        if (!CryptographicOperations.FixedTimeEquals(proof, reply.AsSpan(36))) throw new CryptographicException("Pairing key does not match this iPad.");
        await stream.WriteAsync(HMACSHA256.HashData(pairingKey, Join("client"u8.ToArray(), salt)), ct);
        return new(stream, Derive(pairingKey, salt, "client"), Derive(pairingKey, salt, "server"));
    }

    // Also used by the transport interoperability test receiver.
    public static async Task<SecureChannel> AcceptAsync(Stream stream, byte[] pairingKey, CancellationToken ct)
    {
        if (pairingKey.Length != 32) throw new ArgumentException("Pairing key must be 32 bytes.");
        var hello = new byte[36]; await stream.ReadExactlyAsync(hello, ct);
        if (!hello.AsSpan(0, 4).SequenceEqual("OPD1"u8)) throw new IOException("Invalid handshake.");
        var s = RandomNumberGenerator.GetBytes(32); var salt = Join(hello[4..], s);
        await stream.WriteAsync(Join("OPA1"u8.ToArray(), s, HMACSHA256.HashData(pairingKey, Join("server"u8.ToArray(), salt))), ct);
        var proof = new byte[32]; await stream.ReadExactlyAsync(proof, ct);
        if (!CryptographicOperations.FixedTimeEquals(proof, HMACSHA256.HashData(pairingKey, Join("client"u8.ToArray(), salt)))) throw new CryptographicException("Invalid client proof.");
        return new(stream, Derive(pairingKey, salt, "server"), Derive(pairingKey, salt, "client"));
    }

    public async Task SendAsync(byte type, ReadOnlyMemory<byte> payload, CancellationToken ct)
    {
        if (payload.Length > MaxRecord - 25) throw new IOException("Record too large.");
        await writer.WaitAsync(ct);
        try
        {
            ObjectDisposedException.ThrowIf(disposed != 0, this);
            if (sendSequence == ulong.MaxValue) throw new IOException("Session sequence exhausted.");
            var plain = new byte[payload.Length + 1]; plain[0] = type; payload.CopyTo(plain.AsMemory(1));
            var record = new byte[4 + 8 + plain.Length + 16];
            BinaryPrimitives.WriteUInt32BigEndian(record, (uint)(record.Length - 4));
            BinaryPrimitives.WriteUInt64BigEndian(record.AsSpan(4, 8), sendSequence++);
            var nonce = new byte[12]; record.AsSpan(4, 8).CopyTo(nonce.AsSpan(4));
            sendCipher.Encrypt(nonce, plain, record.AsSpan(12, plain.Length), record.AsSpan(12 + plain.Length, 16), record.AsSpan(4, 8));
            await stream.WriteAsync(record, ct);
        }
        finally { writer.Release(); }
    }

    public async Task<(byte Type, byte[] Payload)> ReceiveAsync(CancellationToken ct)
    {
        var size = new byte[4]; await stream.ReadExactlyAsync(size, ct);
        uint length = BinaryPrimitives.ReadUInt32BigEndian(size);
        if (length < 25 || length > MaxRecord) throw new IOException("Invalid record length.");
        var record = new byte[(int)length]; await stream.ReadExactlyAsync(record, ct);
        if (receiveSequence == ulong.MaxValue || BinaryPrimitives.ReadUInt64BigEndian(record) != receiveSequence) throw new CryptographicException("Out-of-order record.");
        var nonce = new byte[12]; record.AsSpan(0, 8).CopyTo(nonce.AsSpan(4));
        var plain = new byte[record.Length - 24];
        receiveCipher.Decrypt(nonce, record.AsSpan(8, plain.Length), record.AsSpan(record.Length - 16), plain, record.AsSpan(0, 8));
        receiveSequence++;
        return (plain[0], plain[1..]);
    }

    public static byte[] Derive(byte[] key, byte[] salt, string direction) => HKDF.DeriveKey(HashAlgorithmName.SHA256, key, 32, salt, Encoding.UTF8.GetBytes("OpenDisplay/v1/" + direction));
    public static byte[] Join(params byte[][] parts) => parts.SelectMany(p => p).ToArray();
    public static string EncodeKey(byte[] key) => Convert.ToBase64String(key).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        stream.Dispose(); sendCipher.Dispose(); receiveCipher.Dispose();
    }
}
