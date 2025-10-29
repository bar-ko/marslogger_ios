# AWS Secrets Setup

## Настройка AWS credentials

Для работы приложения необходимо настроить AWS credentials. Есть несколько способов:

### 1. Рекомендуемый способ: secrets.json

1. Скопируйте `secrets.json.template` в `secrets.json`:
   ```bash
   cp secrets.json.template secrets.json
   ```

2. Отредактируйте `secrets.json` и укажите ваши AWS credentials:
   ```json
   {
       "aws": {
           "bucket_name": "your-s3-bucket-name",
           "region": "eu-west-1",
           "access_key_id": "YOUR_ACCESS_KEY_ID",
           "secret_access_key": "YOUR_SECRET_ACCESS_KEY"
       }
   }
   ```

3. Файл `secrets.json` автоматически добавлен в `.gitignore` и не будет коммититься в репозиторий.

### 2. Альтернативный способ: Info.plist

Если `secrets.json` не найден, приложение будет искать credentials в `MarsLogger-Info.plist`:

```xml
<key>AWS_S3_BUCKET_NAME</key>
<string>your-bucket-name</string>

<key>AWS_REGION</key>
<string>eu-west-1</string>

<key>AWS_ACCESS_KEY_ID</key>
<string>YOUR_ACCESS_KEY_ID</string>

<key>AWS_SECRET_ACCESS_KEY</key>
<string>YOUR_SECRET_ACCESS_KEY</string>
```

### 3. Environment Variables

Также поддерживаются environment variables:
- `AWS_S3_BUCKET_NAME`
- `AWS_REGION`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

## Приоритет загрузки

1. **secrets.json** (приоритет)
2. **Info.plist**
3. **Environment Variables**
4. **Default values**

## Безопасность

⚠️ **ВАЖНО**: Никогда не коммитьте реальные AWS credentials в репозиторий!

- `secrets.json` добавлен в `.gitignore`
- Используйте `secrets.json.template` для документации
- Для production используйте IAM роли или AWS Secrets Manager
