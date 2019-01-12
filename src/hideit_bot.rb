require 'telegram/bot'
require 'telegram/bot/botan'
require 'mongo'
require_relative 'config'

module Hideit_bot

    class HideItBot
        RegExpParcial = /(^|[^\\])\*(([^\*]|\\\*)*([^\*\\]|\\\*))\*/
        Welcome_message = "Hello 你也是正太控嗎？"

        def self.start()
            Mongo::Logger.logger.level = ::Logger::FATAL

            @@database_cleaner = Thread.new do
                # clean unused data
                mongoc = Mongo::Client.new("mongodb://mongodb:27017/hideitbot")
                counter = 0 # Only run every 30 seconds but sleep one second at a time
                loop do
                    sleep 1
                    counter = (counter + 1) % 30
                    if counter == 29
                        mongoc[:messages].delete_many(:used => false, :created_date => {:$lte => (Time.now - 30).utc})
                    end
                end
            end
        end

        def initialize()
            @bot = Telegram::Bot::Client.new(BotConfig::Telegram_token)
            @messages = Mongo::Client.new("mongodb://mongodb:27017/hideitbot")[:messages]

            rootMessage = @messages.find(:text => Welcome_message)
            if rootMessage.count == 0
              @rootMessageId = save_message(0, Welcome_message, used:true)
            else
              @rootMessageId = rootMessage.to_a[0]["_id"].to_s
            end

            if BotConfig.has_botan_token
                @bot.enable_botan!(BotConfig::Botan_token)
            end
        end

        def listen(&block)
            @bot.listen &block
        end

        def process_update(message)
          begin

            case message
                when Telegram::Bot::Types::InlineQuery
                    id = handle_inline_query(message)
                    if BotConfig.has_botan_token
                      @bot.track('inline_query', message.from.id, {message_length: message.query.length, db_id: id})
                    end

                when Telegram::Bot::Types::CallbackQuery
                    res = message.data
                    begin
                        res = @messages.find("_id" => BSON::ObjectId(message.data)).to_a[0][:text]
                    rescue
                        res = "錯誤 :p\n找不到訊息。"
                    end
                    @bot.api.answer_callback_query(
                        callback_query_id: message.id,
                        text: res,
                        show_alert: true)
                    if BotConfig.has_botan_token
                      @bot.track('callback_query', message.from.id, {db_id: message.data})
                    end

                when Telegram::Bot::Types::ChosenInlineResult
                    message_type, message_id = message.result_id.split(':')
                    @messages.find("_id" => BSON::ObjectId(message_id))
                            .update_one(:$set => {used: true})
                    if BotConfig.has_botan_token
                      @bot.track('chosen_inline', message.from.id, {db_id: message_id, chosen_type: message_type})
                    end


                when Telegram::Bot::Types::Message
                    if message.left_chat_member or message.new_chat_member or message.new_chat_title or message.delete_chat_photo or message.group_chat_created or message.supergroup_chat_created or message.channel_chat_created or message.migrate_to_chat_id or message.migrate_from_chat_id or message.pinned_message
                      return
                    end


                    if message.text == "/start toolong"
                        @bot.api.send_message(chat_id: message.chat.id, text: "Unfortunately, due to telegram's api restrictions we cannot offer this functionality with messages over 200 characters. We'll try to find more options and contact telegram. Sorry for the inconvenience.")
                        if BotConfig.has_botan_token
                          @bot.track('message', message.from.id, message_type: 'toolong')
                        end
                    elsif message.text == "/start"
                        @bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}!\n要使用這個 bot 請在聊天輸入處輸入\n @heidex_bot ")
                        @bot.api.send_message(chat_id: message.chat.id, text: "你也可以在群內使用本bot，而且可以只遮掩部分內容 *像這樣* 需要被遮掩的地方使用星號包覆。")
                        @bot.api.send_message(
                          chat_id: message.chat.id,
                          text: message_to_blocks(Welcome_message),
                          reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                              inline_keyboard: [
                                  Telegram::Bot::Types::InlineKeyboardButton.new(
                                      text: '顯示內容',
                                      callback_data: @rootMessageId
                                  )
                              ]
                          )
                        )
                        if BotConfig.has_botan_token
                          @bot.track('message', message.from.id, message_type: 'hello')
                        end
                    end

            end
          rescue Telegram::Bot::Exceptions::ResponseError => e
            puts "Telegram answered with error #{e}. Continuing"
          end
        end

        def set_webhook(url)
            @bot.api.set_webhook(url: url)
        end

        private

        def save_message(from, text, used: false)
            return @messages.insert_one({user: from, text: text, used: used, created_date: Time.now.utc}).inserted_id.to_s
        end

        def message_to_blocks(message)
            return  message.gsub(/[^\s]/i, "\u2588")
        end

        def message_to_blocks_parcial(message)
            return message.gsub(RegExpParcial) {|s| $1+message_to_blocks($2.gsub(/\*/, ""))}
        end

        def message_clear_parcial(message)
          return message.gsub(RegExpParcial) {|s| $1+$2.gsub(/\\\*/, "*")}
        end

        def handle_inline_query(message)

            default_params = {}
            id = nil

            if message.query == ""
                results = []
                default_params = {
                    switch_pm_text: 'J個Bot怎麼用？',
                    switch_pm_parameter: 'howto'
                }
            elsif message.query.length > 200
                results = []
                default_params = {
                    switch_pm_text: '錯誤：文字訊息過長，請嘗試將文字拆解後分次使用。',
                    switch_pm_parameter: 'toolong'
                }
            else

              id = save_message(message.from.id, message.query)
              results = [
                [id, 'cover:'+id, '傳送普通遮塊', message_to_blocks(message.query), message_to_blocks(message.query)],
                [id, 'generic:'+id, '🌚🌚🌚', '🌚🌚🌚','🌚🌚🌚']
              ]

              if message.query.index(RegExpParcial)
                id_covered = save_message(message.from.id, message_clear_parcial(message.query))
                results.insert(1,
                  [id_covered, 'partial:'+id_covered, '傳送遮掩部分文字', message_to_blocks_parcial(message.query), message_to_blocks_parcial(message.query)],
                )
              end

              results =  results.map do |arr|
                  Telegram::Bot::Types::InlineQueryResultArticle.new(
                      id: arr[1],
                      title: arr[2],
                      description: arr[3],
                      input_message_content: Telegram::Bot::Types::InputTextMessageContent.new(message_text: arr[4]),
                      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                          inline_keyboard: [
                              Telegram::Bot::Types::InlineKeyboardButton.new(
                                  text: '顯示訊息',
                                  callback_data: arr[0]
                              )
                          ]
                      ),
                  )
              end
            end

            @bot.api.answer_inline_query({
                inline_query_id: message.id,
                results: results,
                cache_time: 0,
                is_personal: true
            }.merge!(default_params))
            return id
        end
    end

end