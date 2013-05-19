require 'timeout'

class BlocksController < ApplicationController

  around_filter :timeout

  layout 'application'

  def index
    @per_page = 20
    STORE.instance_eval { @head = nil }
    depth = STORE.get_depth
    depth = params[:depth].to_i  if params[:depth] && params[:depth].to_i < depth
    depth = (@per_page - 1)  if depth < @per_page
    @blocks = []
    if STORE.db.class.name =~ /Sequel/
      @blocks = STORE.db[:blk].select(:hash, :depth).filter("depth <= ?", depth).order(:depth).limit(@per_page).reverse
    else
      @per_page.times { @blocks << STORE.get_block_by_depth(depth); depth -= 1 }
    end
    @page_title = "Recent Blocks"
  end

  def block
    @block = STORE.get_block(params[:id])
    return render :text => "Block #{params[:id]} not found."  unless @block
    respond_to do |format|
      format.html { @page_title = "Block Details" }
      format.json { render :text => @block.to_json }
      format.bin { render :text => @block.to_payload }
    end
  end

  def tx
    @tx = STORE.get_tx(params[:id])
    return render :text => "Tx #{params[:id]} not found."  unless @tx
    respond_to do |format|
      format.html { @page_title = "Transaction Details" }
      format.json { render :text => @tx.to_json }
      format.bin { render :text => @tx.to_payload }
    end
  end

  def address
    @address = params[:id]
    unless Bitcoin.valid_address?(@address)
      return render :text => "Address #{params[:id]} is invalid."
    end
    @hash160 = Bitcoin.hash160_from_address(@address)

    @addr = STORE.db[:addr][hash160: @hash160.to_sequel_blob]
    return render text: "Address not found."  unless @addr

    @addr_data = { address: @address, hash160: @hash160,
      tx_in_sz: 0, tx_out_sz: 0, btc_in: 0, btc_out: 0 }

    @addr_txouts = STORE.db[:addr_txout].where(addr_id: @addr[:id])

    if @addr_txouts.count > (BB_CONFIG['max_addr_txouts'] || 100)
      return render text: "Too many outputs for this address (#{@addr_txouts.count})"
    end

    respond_to do |format|
      format.html do
        @page_title = "Address #{@address}"
        @tx_list = render_to_string partial: "address_tx"
      end
      format.json { render text: address_json(@addr_data, @addr_txouts) }
    end
  end

  def name
    @name = params[:name]
    @names = STORE.name_history(@name)
    @current = @names.last
    return render text: "NOT FOUND"  unless @current
  end

  caches_page :script
  def script
    tx_hash, txin_idx = params[:id].split(":")
    @tx = STORE.get_tx(tx_hash)
    @txin = @tx.in[txin_idx.to_i]
    @txout = @txin.get_prev_out
    @script = Bitcoin::Script.new(@txin.script_sig + @txout.pk_script)
    @result = @script.run do |pubkey, sig, hash_type|
      hash = @tx.signature_hash_for_input(@txin.tx_idx, nil, @txout.pk_script)
      Bitcoin.verify_signature(hash, sig, pubkey.unpack("H*")[0])
    end
    @debug = @script.debug
    @page_title = "Script Details"
  end

  # search for given (part of) block/tx/address.
  # also try to account for 'half bytes' when hex string is cut off.
  # TODO: currently it just looks for whole hashes/addrs
  def search
    @id = params[:search]

    if Bitcoin.valid_address?(@id)
      return redirect_to address_path(@id)
    elsif @id.to_i.to_s == @id
      block = STORE.get_block_by_depth(@id.to_i)
      return redirect_to(block_path(block.hash))  if block
    elsif STORE.db.class.name =~ /Sequel/
      return  if search_block(@id)
      return  if search_tx(@id)
      return  if search_name(@id)
      # if @id.size % 2 == 0
      #   return  if search_block(@id)
      #   return  if search_tx(@id)
      #   t = @id.split; t.pop; t.shift; t = t.join
      #   return  if search_block(t)
      #   return  if search_tx(t)
      # else
      #   return  if search_block(@id[0..-2])
      #   return  if search_block(@id[1..-1])
      #   return  if search_tx(@id[0..-2])
      #   return  if search_tx(@id[1..-1])
      # end
    elsif @id =~ /^0000/
      redirect_to block_path(@id)
    else
      redirect_to tx_path(@id)
    end
    render :text => "NOT FOUND"
  end

  def unconfirmed
    @tx = STORE.get_unconfirmed_tx
    respond_to do |format|
      format.html { @page_title = "Unconfirmed Tx (#{@tx.size})" }
      format.json { render :text => @tx.map(&:to_hash).to_json }
    end
  end

  def names
    @per_page = 20
    @page = (params[:page] || 1).to_i
    @offset = @per_page * (@page - 1)
    @max = STORE.db[:names].count
    @names = STORE.db[:names].order(:txout_id).reverse.limit(@per_page, @offset)
    @names = @names.map {|n| STORE.wrap_name(n) }
  end

  def about
    @page_title = "About"
  end

  def source
    git_rev = `git rev-parse --verify HEAD`.strip
    public_name = "block_browser-#{git_rev[0..8]}"
    tar_file = File.join(Rails.root, "public/#{public_name}.tar.bz2")
    unless File.exist?(tar_file)
      tmpdir = Dir.mktmpdir
      Dir.mkdir(File.join(tmpdir, public_name))
      `git clone . #{tmpdir}/#{public_name}`
      Dir.chdir(File.join(tmpdir, public_name)) { `git checkout #{git_rev}` }
      Dir.chdir(tmpdir) { `tar -cjf #{tar_file} #{public_name}` }
      FileUtils.rm_rf tmpdir
    end
    redirect_to "/#{public_name}.tar.bz2"
  end

  private

  def search_block(part)
    # blob = ("%" + [part].pack("H*") + "%").to_sequel_blob
    # hash = STORE.db[:blk].filter(:hash.like(blob)).first[:hash].unpack("H*")[0]
    hash = STORE.db[:blk][hash: part.htb.to_sequel_blob][:hash].hth
    redirect_to block_path(hash)
  rescue
    nil
  end

  def search_tx(part)
    # blob = ("%" + [part].pack("H*") + "%").to_sequel_blob
    # hash = STORE.db[:tx].filter(:hash.like(blob)).first[:hash].unpack("H*")[0]
    hash = STORE.db[:tx][hash: part.htb.to_sequel_blob][:hash].hth
    redirect_to tx_path(hash)
  rescue
    nil
  end

  def search_name(part)
    return nil  unless Bitcoin.namecoin?
    name = STORE.name_show(part)
    redirect_to name_path(name.name)  if name
  rescue
    nil
  end

  def address_json(addr_data, addr_txouts)
    transactions = {}
    addr_txouts.each do |addr_txout|
      txout = STORE.db[:txout][id: addr_txout[:txout_id]]
      next  unless tx_data = tx_data_from_id(txout[:tx_id])
      addr_data[:tx_in_sz] += 1
      addr_data[:btc_in] += txout[:value]
      transactions[tx_data['hash']] = tx_data
      txin = STORE.db[:txin][prev_out: tx_data['hash'].htb.reverse.to_sequel_blob,
                             prev_out_index: txout[:tx_idx]]
      next  unless txin && tx_data = tx_data_from_id(txin[:tx_id])
      addr_data[:tx_out_sz] += 1
      addr_data[:btc_out] += txout[:value]
      transactions[tx_data['hash']] = tx_data
    end
    addr_data[:balance] = addr_data[:btc_in] - addr_data[:btc_out]
    addr_data[:tx_sz] = transactions.size
    addr_data[:transactions] = transactions
    JSON.pretty_generate(addr_data)
  end

  def tx_data_from_id tx_id
    tx = STORE.get_tx_by_id(tx_id)
    blk_tx = STORE.db[:blk_tx][tx_id: tx.id]
    blk = STORE.db[:blk][id: blk_tx[:blk_id], chain: 0]
    return nil  unless blk

    data = tx.to_hash
    data['block'] = blk[:hash].hth
    data['blocknumber'] = blk[:depth]
    data['time'] = Time.at(blk[:time]).strftime("%Y-%m-%d %H:%M:%S")
    data
  end

  def timeout
    begin
      Timeout.timeout(BB_CONFIG['timeout']) { yield }
    rescue Timeout::Error
      return render text: "Request took too long."
    end
  end
end
