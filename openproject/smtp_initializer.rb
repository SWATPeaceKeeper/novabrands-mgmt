# Force ActionMailer SMTP settings from OpenProject configuration.
# Workaround for OpenProject 17 not applying env vars to ActionMailer.
Rails.application.config.after_initialize do
  cfg = OpenProject::Configuration
  next unless cfg.email_delivery_method == :smtp

  ActionMailer::Base.delivery_method = :smtp
  ActionMailer::Base.smtp_settings = {
    address: cfg.smtp_address,
    port: cfg.smtp_port,
    user_name: cfg.smtp_user_name,
    password: cfg.smtp_password,
    authentication: cfg.smtp_authentication.presence&.to_sym,
    enable_starttls_auto: cfg.smtp_enable_starttls_auto
  }.compact
end
