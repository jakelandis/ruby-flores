require "flores/namespace"

module Flores::PKI
  # A certificate signing request.
  #
  # From here, you can configure a certificate to be created based on your
  # desired configuration.
  #
  # Example making a root CA:
  #
  #     key = OpenSSL::PKey::RSA.generate(4096, 65537)
  #     csr = Flores::PKI::CertificateSigningRequest.new
  #     csr.subject = "OU=Fancy Pants Inc."
  #     certificate = csr.create_root(key)
  #
  # Example making an intermediate CA:
  #     
  #     root_key = OpenSSL::PKey::RSA.generate(4096, 65537)
  #     root_csr = Flores::PKI::CertificateSigningRequest.new
  #     root_csr.subject = "OU=Fancy Pants Inc."
  #     root_csr.public_key = root_key.public
  #     root_certificate = csr.create_root(root_key)
  #
  #     intermediate_key = OpenSSL::PKey::RSA.generate(4096, 65537)
  #     intermediate_csr = Flores::PKI::CertificateSigningRequest.new
  #     intermediate_csr.public_key = intermediate_key.public
  #     intermediate_csr.subject = "OU=Fancy Pants Inc. Intermediate 1"
  #     intermediate_certificate = csr.create_intermediate(root_certificate, root_key)
  class CertificateSigningRequest
    # raised when an invalid signing configuration is given
    class InvalidRequest < StandardError; end

    # raised when invalid data is present in a certificate request
    class InvalidData < StandardError; end

    # raised when an invalid subject (format, or whatever) is given in a certificate request
    class InvalidSubject < InvalidData; end

    # raised when an invalid time value is given for a certificate request
    class InvalidTime < InvalidData; end

    def initialize
      self.serial = Flores::PKI.random_serial
      self.digest_method = default_digest_method
    end

    private

    def validate_subject(value)
      OpenSSL::X509::Name.parse(value)
    rescue OpenSSL::X509::NameError => e
      raise InvalidSubject, "Invalid subject '#{value}'. (#{e})"
    rescue TypeError => e
      # Bug(?) in MRI 2.1.6(?)
      raise InvalidSubject, "Invalid subject '#{value}'. (#{e})"
    end

    def subject=(value)
      @subject = validate_subject(value)
    end

    attr_reader :subject

    def subject_alternates=(values)
      @subject_alternates = values
    end

    attr_reader :subject_alternates

    def public_key=(value)
      @public_key = validate_public_key(value)
    end

    def validate_public_key(value)
      raise InvalidData, "public key must be a OpenSSL::PKey::PKey" unless value.is_a? OpenSSL::PKey::PKey
      value
    end

    attr_reader :public_key

    def start_time=(value)
      @start_time = validate_time(value)
    end

    attr_reader :start_time

    def expire_time=(value)
      @expire_time = validate_time(value)
    end

    attr_reader :expire_time

    def validate_time(value)
      raise InvalidTime, "#{value.inspect} (class #{value.class.name})" unless value.is_a?(Time)
      value
    end

    def certificate
      return @certificate  if @certificate
      @certificate = OpenSSL::X509::Certificate.new

      # RFC5280
      # > 4.1.2.1.  Version
      # > version MUST be 3 (value is 2).
      #
      # Version value of '2' means a v3 certificate.
      @certificate.version = 2

      @certificate.subject = subject
      @certificate.not_before = start_time
      @certificate.not_after = expire_time
      @certificate.public_key = public_key
      @certificate
    end

    def default_digest_method
      OpenSSL::Digest::SHA256.new
    end

    def self_signed?
      @signing_certificate.nil?
    end

    def validate!
      if self_signed?
        if @signing_key.nil?
          raise InvalidRequest, "No signing_key given. Cannot sign key."
        end
      elsif @signing_certificate.nil? && @signing_key
        raise InvalidRequest, "signing_key given, but no signing_certificate is set"
      elsif @signing_certificate && @signing_key.nil?
        raise InvalidRequest, "signing_certificate given, but no signing_key is set"
      end
    end

    def create
      validate!
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = certificate
      extensions.issuer_certificate = self_signed? ? certificate : signing_certificate

      certificate.issuer = extensions.issuer_certificate.subject
      certificate.add_extension(extensions.create_extension("subjectKeyIdentifier", "hash", false))

      if want_signature_ability?
        # Create a CA.
        certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
        # Rough googling seems to indicate at least keyCertSign is required for CA and intermediate certs.
        certificate.add_extension(extensions.create_extension("keyUsage", "keyCertSign, cRLSign, digitalSignature", true))
      else
        # Create a client+server certificate
        #
        # It feels weird to create a certificate that's valid as both server and client, but a brief inspection of major
        # web properties (apple.com, google.com, yahoo.com, github.com, fastly.com, mozilla.com, amazon.com) reveals that
        # major web properties have certificates with both clientAuth and serverAuth extended key usages. Further,
        # these major server certificates all have digitalSignature and keyEncipherment for key usage.
        #
        # Here's the command I used to check this:
        #    echo mozilla.com apple.com github.com google.com yahoo.com fastly.com elastic.co amazon.com \
        #    | xargs -n1 sh -c 'openssl s_client -connect $1:443 \
        #    | sed -ne "/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p" \
        #    | openssl x509 -text -noout | sed -ne "/X509v3 extensions/,/Signature Algorithm/p" | sed -e "s/^/$1 /"' - \
        #    | grep -A2 'Key Usage'
        certificate.add_extension(extensions.create_extension("keyUsage", "digitalSignature, keyEncipherment", true))
        certificate.add_extension(extensions.create_extension("extendedKeyUsage", "clientAuth, serverAuth", false))
      end

      if @subject_alternates
        certificate.add_extension(extensions.create_extension("subjectAltName", @subject_alternates.join(",")))
      end
        
      certificate.serial = OpenSSL::BN.new(serial)
      certificate.sign(signing_key, digest_method)
      certificate
    end

    # Set the certificate which is going to be signing this request.
    def signing_certificate=(certificate)
      raise InvalidData, "signing_certificate must be an OpenSSL::X509::Certificate" unless certificate.is_a?(OpenSSL::X509::Certificate)
      @signing_certificate = certificate
    end
    attr_reader :signing_certificate

    attr_reader :signing_key
    def signing_key=(private_key)
      raise InvalidData, "signing_key must be an OpenSSL::PKey::PKey (or a subclass)" unless private_key.is_a?(OpenSSL::PKey::PKey)
      @signing_key = private_key
    end

    def want_signature_ability=(value)
      raise InvalidData, "want_signature_ability must be a boolean" unless value == true || value == false
      @want_signature_ability = value
    end

    def want_signature_ability?
      @want_signature_ability == true
    end

    attr_reader :digest_method
    def digest_method=(value)
      raise InvalidData, "digest_method must be a OpenSSL::Digest (or a subclass)" unless value.is_a?(OpenSSL::Digest)
      @digest_method = value
    end

    attr_reader :serial
    def serial=(value)
      begin
        Integer(value)
      rescue
        raise InvalidData, "Invalid serial value. Must be a number (or a String containing only nubers)"
      end
      @serial = value
    end

    public(:serial, :serial=)
    public(:subject, :subject=)
    public(:subject_alternates, :subject_alternates=)
    public(:public_key, :public_key=)
    public(:start_time, :start_time=)
    public(:expire_time, :expire_time=)
    public(:digest_method, :digest_method=)
    public(:want_signature_ability?, :want_signature_ability=)
    public(:signing_key, :signing_key=)
    public(:signing_certificate, :signing_certificate=)
    public(:create)
  end # class CertificateSigningRequest
end
