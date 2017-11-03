
minimist = require 'minimist'
{make_esc} = require 'iced-error'
request = require 'request'

class Data

  constructor : () ->

class SendTo

  constructor : ({@addr, @per_mille}) ->

  @parse : (s, cb) ->
    v = s.split /:/
    if v.length > 2 or (v.length is 2 and (isNaN(m = parseInt(v[1])) or m < 0))
      err = new Error "bad send to: #{s}"
    else
      ret = new SendTo { addr : v[0], per_mille : (m or 0) }
    cb err, ret

class PrevTx

  constructor : ({@addr, @index}) ->

  @parse : (s, cb) ->
    v = s.split /:/
    if v.length isnt 2 or (v.length is 2 and isNaN(i = parseInt(v[1])))
      err = new Error "bad PrevTx: #{s}; need <txid>:<int>"
    else
      ret = new PrevTx { addr : v[0], index : i }
    cb err, ret

class Main

  constructor : () ->

  req : (uri, cb) ->
    await request { uri, json : true}, defer err, res
    cb err, res

  parse_sendto : ({arg}, cb) ->
    esc = make_esc cb, "parse_sendto"
    v = out = err = null
    if typeof(arg) is 'string'
      v = [ arg ]
    else if typeof(arg) is 'object' and Array.isArray(arg)
      v = arg
    else
      err = new Error "bad sendto: #{arg}"
    if v?
      out = []
      for s in v
        for e in s.split /,/
          await SendTo.parse e, esc defer x
          out.push x
    cb null, out

  santify_check_sendto_list : ({send_to_list}, cb) ->
    err = null
    tot = 0
    seen = {}
    for s in send_to_list
      tot += s.per_mille
      if seen[s.addr]
        return cb new Error "duplicated send-to: #{s.addr}"
      seen[s.addr] = true
    if tot not in [ 0, 1000 ]
      err = new Error "send_tos must sum to 1000 or 0"
    cb err

  parse_args : ({argv}, cb) ->
    esc = make_esc cb, "parse_args"
    data = new Data
    args = minimist argv, { string : [ "send-to", "prev-tx", "prev-addr" ] }
    needed = [ "send-to", "prev-tx", "prev-addr", "fee", "btc-price"]
    for n in needed
      if not args[n]?
        return cb new Error "missing needed argument: --#{n}"
    await @parse_sendto { arg : args["send-to"] }, esc defer data.send_to_list
    await @santify_check_sendto_list { send_to_list : data.send_to_list }, esc defer()
    await PrevTx.parse args["prev-tx"], esc defer data.prev_tx
    err = null
    data.prev_addr = args["prev-addr"]
    if isNaN(parseInt((data.fee = args.fee)))
      err = new Error "need a fee in satoshi via --fee"
    else if isNaN(parseInt(data.btc_price = args["btc-price"]))
      err = new Error "need a BTC price via --btc-price"
    cb err, data

  check_prev_transaction : (opts, cb) ->
    esc = make_esc cb, "check_prev_transaction"
    await @req { uri : "https://blockchain.info/rawtx/#{data.prev_tx}" }, esc defer body
    console.log body
    cb null

  prompt_for_private_key : (opts, cb) ->
    cb null

  check_private_public_match : (opts, cb) ->
    cb null

  make_new_transaction : (opts, cb) ->
    cb null

  verify_change : (opts, cb) ->
    cb null

  verify_fee : (opts, cb) ->
    cb null

  output : (opts, cb) ->
    cb null

  run : (argv, cb) ->
    esc = make_esc cb, "run"
    await @parse_args {argv}, esc defer data
    await @check_prev_transaction {data}, esc defer()
    await @prompt_for_private_key {data}, esc defer()
    await @check_private_public_match {data}, esc defer()
    await @make_new_transaction {data}, esc defer()
    await @verify_change {data}, esc defer()
    await @verify_fee {data}, esc defer()
    await @output {data}, esc defer()
    cb null

main = () ->
  m = new Main()
  await m.run process.argv[2...], defer err
  rc = 0
  if err?
    console.error err.toString()
    rc = 2
  process.exit rc

main()