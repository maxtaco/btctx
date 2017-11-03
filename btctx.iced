
minimist = require 'minimist'
{make_esc} = require 'iced-error'
request = require 'request'
read = require 'read'
bitcoin = require 'bitcoinjs-lib'

class BTCAmount

  constructor : ( {@satoshi, @price}) ->
  btc : () -> @satoshi / (100*1000*1000)
  dollars : () -> @price * @btc()
  toString : () -> "$#{@dollars()} (฿#{@btc()})"

  @from_dollars : ({amt, price}) ->
    new BTCAmount { price, satoshi : (amt/price) * 100 * 1000 * 1000 }

  sub : (y) -> return new BTCAmount { satoshi : (@satoshi - y.satoshi), @price }
  to_satoshi : () -> @satoshi
  per_mille : (div) -> return new BTCAmount { satoshi : Math.floor(@satoshi*div/1000), @price }
  clone : () -> new BTCAmount { @satoshi, @price }

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

  req : ({uri}, cb) ->
    await request { uri, json : true}, defer err, res
    ret = null
    if not (ret = res.body)?
      err = new Error "bad JSON request for #{uri}"
    cb err, ret

  # One the command line, you can either do this:
  #
  #   --send-to 1LLmEMhqHP264Qqpv83Sf3s9hhSicJXtXK,1PUyf5STtMWNeFjvhbJz648SYume9tBkMf
  #
  # Or this:
  #   --send-to 1LLmEMhqHP264Qqpv83Sf3s9hhSicJXtXK --send-to 1PUyf5STtMWNeFjvhbJz648SYume9tBkMf
  #
  # And they mean the same thing. This will split the output across those two different addresses.
  # If you want an unequal split, you can do this:
  #
  #   --send-to 1LLmEMhqHP264Qqpv83Sf3s9hhSicJXtXK:400 --send-to 1PUyf5STtMWNeFjvhbJz648SYume9tBkMf:600
  #
  # Which will put 40% into the first wallet and 60% into the second.  By default, it's an
  # even split, but if you specify PerMilles (rather than PerCents), then they must
  # add up to 1000.  See
  #
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

  # See the above description in parse_sendto
  sanity_check_sendto_list : ({send_to_list}, cb) ->
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
    needed = [ "send-to", "prev-tx", "prev-addr", "fee", "approx-btc-price", "approx-value" ]
    for n in needed
      if not args[n]?
        return cb new Error "missing needed argument: --#{n}"
    await @parse_sendto { arg : args["send-to"] }, esc defer data.send_to_list
    await @sanity_check_sendto_list { send_to_list : data.send_to_list }, esc defer()
    await PrevTx.parse args["prev-tx"], esc defer data.prev_tx
    err = null
    data.prev_addr = args["prev-addr"]
    if isNaN(parseInt((data.fee = args.fee)))
      err = new Error "need a fee in *dollars* via --fee"
    else if isNaN(parseInt(data.approx_btc_price = args["approx-btc-price"]))
      err = new Error "need a BTC price in USD/BTC via --approx-btc-price"
    else if isNaN(parseInt(data.approx_value = args["approx-value"]))
      err = new Error "need an approximate value of this transaction in USD via --approx-value"
    cb err, data

  check_prev_transaction : ({data}, cb) ->
    esc = make_esc cb, "check_prev_transaction"
    await @req { uri : "https://blockchain.info/rawtx/#{data.prev_tx.addr}" }, esc defer body
    output = body.out[data.prev_tx.index]
    if output.addr isnt data.prev_addr
      err = new Error "got different previous address: #{output.addr}"
    else
      data.budget = new BTCAmount { satoshi : output.value, price : data.btc_price }
      diff = data.budget.dollars() / data.approx_value
      if diff < .8 or diff > 1.2
        err = new Error "wrong approximate value for transaction; actual was: #{data.budget.toString()}"
    cb err

  prompt_for_private_key : ({data}, cb) ->
    esc = make_esc cb, "prompt_for_private_key"
    await read { prompt : "private key> "}, esc defer wif
    try
      data.priv_key = bitcoin.ECPair.fromWIF wif
    catch e
      err = new Error "failed to import private key #{wif}: #{e.toString()}"
    cb err

  check_private_public_match : ({data}, cb) ->
    if (a = data.priv_key.getAddress()) isnt (b = data.prev_addr)
      err = new Error "private signing key (#{a}) doesn't match previous address (#{b})"
    cb err

  check_bitcoin_price : ({data}, cb) ->
    esc = make_esc cb, "check_bitcoin_price"
    await @req { uri : "https://blockchain.info/ticker" }, esc defer body
    approx_price = data.approx_btc_price
    data.btc_price = body.USD.last
    diff = data.btc_price / approx_price
    err = null
    if diff < .8 or diff > 1.2
      err = new Error "wrong approximate BTC price: #{approx_price} v #{data.btc_price}"
    cb err

  output : ({data}, cb) ->
    tx = new bitcoin.TransactionBuilder()
    tx.addInput(data.prev_tx.addr, data.prev_tx.index)
    def_per_mille = 1000 / data.send_to_list.length
    gross = data.budget
    fee = BTCAmount.from_dollars { amt: data.fee, price: data.btc_price }
    console.log "Fee: #{fee.toString()}"
    net = data.budget.sub fee
    rem = net.clone()
    for s in data.send_to_list
      amt = net.per_mille(s.per_mille or def_per_mille)
      console.log " -> To #{s.addr}: #{amt.toString()}"
      tx.addOutput(s.addr, amt.to_satoshi())
      rem = rem.sub amt
    console.log "Rem: #{rem.toString()}"
    tx.sign 0, data.priv_key
    console.log tx.build().toHex()
    err = null
    if (s = rem.to_satoshi()) < 0
      err = new Error "no money left in this transaction"
    else if rem.dollars() > .01
      err = new Error "left more than a penny"
    cb err

  run : (argv, cb) ->
    esc = make_esc cb, "run"
    await @parse_args {argv}, esc defer data
    await @check_bitcoin_price { data}, esc defer()
    await @check_prev_transaction {data}, esc defer()
    await @prompt_for_private_key {data}, esc defer()
    await @check_private_public_match {data}, esc defer()
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
