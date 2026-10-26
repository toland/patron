# Regenerates the client certificate fixtures used by the mutual TLS specs.
# Run with `ruby spec/support/certs/generate_client_certs.rb`
require 'openssl'

dir = __dir__
password = 'patron'
not_after = Time.utc(2045, 1, 1)

def name(cn)
  OpenSSL::X509::Name.parse("/C=US/O=Patron Test Certificate/CN=#{cn}")
end

ca_key = OpenSSL::PKey::RSA.new(2048)
ca = OpenSSL::X509::Certificate.new
ca.version = 2
ca.serial = 1
ca.subject = name('Patron Test Client CA')
ca.issuer = ca.subject
ca.public_key = ca_key.public_key
ca.not_before = Time.utc(2025, 1, 1)
ca.not_after = not_after
ef = OpenSSL::X509::ExtensionFactory.new(ca, ca)
ca.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
ca.add_extension(ef.create_extension('keyUsage', 'keyCertSign,cRLSign', true))
ca.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash'))
ca.sign(ca_key, OpenSSL::Digest::SHA256.new)

client_key = OpenSSL::PKey::RSA.new(2048)
client = OpenSSL::X509::Certificate.new
client.version = 2
client.serial = 2
client.subject = name('patron-test-client')
client.issuer = ca.subject
client.public_key = client_key.public_key
client.not_before = ca.not_before
client.not_after = not_after
ef = OpenSSL::X509::ExtensionFactory.new(ca, client)
client.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE', true))
client.add_extension(ef.create_extension('keyUsage', 'digitalSignature,keyEncipherment', true))
client.add_extension(ef.create_extension('extendedKeyUsage', 'clientAuth'))
client.sign(ca_key, OpenSSL::Digest::SHA256.new)

File.write(File.join(dir, 'client_ca.pem'), ca.to_pem)
File.write(File.join(dir, 'client_cert.pem'), client.to_pem)
File.write(File.join(dir, 'client_key.pem'), client_key.export(OpenSSL::Cipher.new('aes-256-cbc'), password))

p12 = OpenSSL::PKCS12.create(password, 'patron-test-client', client_key, client, nil,
  'PBE-SHA1-3DES', 'PBE-SHA1-3DES')
File.binwrite(File.join(dir, 'client.p12'), p12.to_der)
