variable "discord_webhook_url" {
  description = "Lakeflow 알림을 중계할 Discord 채널 웹훅 URL. TF_VAR_discord_webhook_url 환경변수로 주입."
  type        = string
  sensitive   = true
}