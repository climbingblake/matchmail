require 'sinatra'
require 'csv'
require 'mail'
require 'digest'
require 'sequel'
require 'email_address'
require 'tempfile'
require 'fileutils'

enable :sessions

set :public_folder, File.dirname(__FILE__) + '/public'


EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
ALPHA       = ['A','B','C','D','E','F','G','H','I']
LIST_LIMIT  = 10

DB = Sequel.connect('sqlite://hashes.db')

DB.create_table? :hash_sets do
  primary_key :id
  String :name
  DateTime :created_at
  Integer :count
end

DB.create_table? :hashes do
  primary_key :id
  foreign_key :hash_set_id, :hash_sets
  String :email_hash
end

def valid_email_format?(email)
  email =~ EMAIL_REGEX
end

def process_email(email)
  return nil if !valid_email_format?(email)
  Digest::SHA256.hexdigest(email.downcase)
  
rescue Mail::Field::ParseError => e
  puts e
end

get '/' do
  erb :index
end

get '/upload' do   
  erb :upload
end 

post '/upload' do  
  if params[:file] and params[:name]
    filename  = params[:file][:filename]
    file      = params[:file][:tempfile]
    name      = params[:name]
    cnt       = 0

    # Create a new temporary file
    temp_file = Tempfile.new(['upload', File.extname(filename)])
    
    # Copy the uploaded file to the temporary file
    FileUtils.copy_stream(file, temp_file)    
    session[:uploaded_file_path] = temp_file.path
    session[:name] = name
    redirect '/process_upload'
  else
    return "No file uploaded"
  end
  redirect '/wrong'
end

post '/compare' do   
  @set_info = [] 
  @comparisons = []
  if params[:hash_sets] && params[:hash_sets].length >= 2
    ids = params[:hash_sets].map(&:to_i)

    @set_info = ids.each_with_index.map do |id,index|
      email_hashes = DB[:hashes].where(hash_set_id: id).select_map(:email_hash)
      name = DB[:hash_sets].where(id: id).get(:name)
      {
        id: id,
        name: name,
        count: email_hashes.length,   
        hashes: email_hashes,
        alpha: ALPHA[index]     
      }
    end    

    @set_info.combination(2).each do |id1, id2|
      set1 = id1[:hashes]
      set2 = id2[:hashes]
      common = (set1 & set2).length
      total = [set1.length, set2.length].max
      percentage = (common.to_f / total * 100).round(2)

      @comparisons << {
        set1_id: id1,
        set2_id: id2,
        set1_name: id1[:name],
        set2_name: id2[:name],
        common_count: common,
        percentage: percentage,
        set1_alpha: id1[:alpha],
        set2_alpha: id2[:alpha]
      }
    end
    
    @comparison_result = "Comparison complete. See results below."
  else
    @comparison_result = "Please select at least two sets to compare."
  end
  erb :compare
end

get '/list' do 
  @hash_sets = DB[:hash_sets].order(Sequel.desc(:created_at)).all
  erb :list
end

get '/delete' do
  @hash_sets = DB[:hash_sets].order(Sequel.desc(:created_at)).all
  erb :delete
end 

get '/delete_hash_sets' do
  delete_hash_set(params[:hash_set]) if params[:hash_set]
  params[:hash_sets].each(&method(:delete_hash_set)) if params[:hash_sets]
  redirect '/delete'
end

get '/download/:filename' do
  filename = params[:filename]  
  file_path = File.join(settings.public_folder, 'emails.csv')

  if File.exist?(file_path)    
    send_file(file_path, :filename => filename, :type => 'Application/octet-stream')    
  else
   halt 404, "File not found"
  end
end

get '/process_upload' do
  if session[:uploaded_file_path] && File.exist?(session[:uploaded_file_path])
    # Read and process the file
    content = File.read(session[:uploaded_file_path])
    cnt = 0

    if content     
      hash_set = DB[:hash_sets].insert(name: session[:name], created_at: Time.now)
      
      # CSV.foreach(session[:uploaded_file_path]) do |row|
      #   if (hash = process_email(row[0]))
      #     DB[:hashes].insert(hash_set_id: hash_set, email_hash: hash)
      #     cnt = cnt+1 
      #   end
      # end

      hashes_to_insert = []
      CSV.foreach(session[:uploaded_file_path]) do |row|
        if (hash = process_email(row[0]))
          hashes_to_insert << { hash_set_id: hash_set, email_hash: hash }
        end
      end

      if hashes_to_insert.any?
        DB[:hashes].multi_insert(hashes_to_insert)
        cnt = hashes_to_insert.size
      end
      
      DB[:hash_sets].where(id: hash_set).update(count: cnt)
  
      #limit the number of saved sets
      if DB[:hash_sets].count.to_i > LIST_LIMIT
        delete_hash_set(DB[:hash_sets].order(Sequel.asc(:created_at)).first[:id])    
      end
  
      "File processed and #{cnt} hashes stored. <a href='/list'>Go to List Page</a>"
    else      
      "No file uploaded or name provided."
    end
      
    session.delete(:uploaded_file_path)
    session.delete(:name)
    
    "Processed file. It contained #{cnt} lines.<br><a href='/list'>Go to List Page</a><br><a href='/upload'>Upload another</a>"
  else
    "No file to process or file not found."
  end
end

def delete_hash_set id
  DB[:hashes].where(hash_set_id: id).delete
  DB[:hash_sets].where(id: id).delete
end
