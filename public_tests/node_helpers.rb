require 'socket' #Required import to allow server connection 
require 'thread'

$port = nil
$hostname = nil

# ----------------------- Loop methods -----------------------#
class Neighbor
	attr_accessor :name, :cost

	def initialize(name, cost)
		@name = name
		@cost = cost
	end
	
	def ==(other)
		self.name == other
	end
	
	def to_s
		"#{name};#{cost}"
	end

end

# ----------------- Classes ------------------ #

def listeningloop()
	$server = TCPServer.new $port
	loop do
		Thread.fork($server.accept) do |clientSocket|
			$serverSockets.push(clientSocket)
		end
	end
end

def receivingloop()
	loop do
		#$semaphore.synchronize {
			$serverSockets.each do |servSocket|
			  	ready = IO.select([servSocket])
	    		readable = ready[0] #0 is sockets for reading

	    		readable.each do |socket|
	                buf = socket.recv(2048)
	                if buf.length == 0
	                    #STDOUT.puts "The payload exceeds 1024 bytes."
	                else
	                	buf.chop! #Remove the last character, which should be `
	                	msgs = buf.split("`")
	                	msgs.each do |msg|
	                		$internalMsgQueue.push(msg)
	                	end
	                end
	            end

	            readable.clear
			end
		#}
	end
end

#Need to parse messages and clear buffer as messages are read
def msgHandler()
	loop do
		#$semaphore.synchronize {
			if !$internalMsgQueue.empty?
				str = $internalMsgQueue.pop
				#STDOUT.puts "#{$hostname} handling this message: #{str}"
				args = str.split(" ")
				cmd = args[0]

				case (cmd)
				when "APPLYEDGE"; handleEntryAdd(args[1], args[2])
				when "LSA"; handleLSA(args[1], args[2], args[3], args[4])
				else STDOUT.puts "ERROR: INVALID COMMAND \"#{cmd}\""
				end
			end
		#}
	end
end

def dijkstras()
	loop do
		if($clock_val > $update_time)
			$update_time = $clock_val + $updateInterval

			createOwnLSA()
			performDijkstra()
		end
	end
end

def handleLSA(origName, origSeqNum, origChange, neighbors)
	#Update the cost of the neighbors here with the sequence number
	neighborGroup = neighbors.split(",")

	if(!$graphInfo.has_key?(origName) || $graphInfo[origName][0] < origSeqNum.to_i)
		if (origChange.to_i == 0)
			$graphInfo[origName][0] = origSeqNum.to_i
		else
			$network_change = 1
			$graphInfo[origName] = Array.new()
			$graphInfo[origName][0] = origSeqNum.to_i
			$graphInfo[origName][1] = Array.new()
			neighborGroup.each do |neighbor_string|
				neighborArr = neighbor_string.split(";")
				neighborName = neighborArr[0]
				neighborCost = neighborArr[1].to_i

				$graphInfo[origName][1].push(Neighbor.new(neighborName, neighborCost))
			end
		end

		floodMessage("LSA #{origName} #{origSeqNum} #{origChange} #{neighbors}`")
	end
end

def createOwnLSA()
	#puts "Sending LSA"
	message = "LSA #{$hostname} #{$seq_val.to_s} #{$local_change} "
	$local_change = 0
	$seq_val = $seq_val + 1;
	str = ""
	$neighbors.each do |neighbor|
		message << "#{neighbor.to_s},"
	end
	message.chop! #Remove the last character, which will be a space

	floodMessage("#{message}`")
end

def floodMessage(message)
	$neighbors.each do |neighbor|
		if $nodeToSocket.has_key?(neighbor.name)
			$nodeToSocket[neighbor.name].write(message)
		end
	end
end

#DIJKSTRA
def performDijkstra()
	if($local_change == 0 && $network_change == 0)
		return
	end
	#We have the neighbors, so just initialize all distances to Infinity
	nodesToDistance = {}
	nodesToPrevious = {}

	nodeQueue = []
	$nodeToPort.each do |node, sock|
		nodesToDistance[node] = Float::INFINITY
		nodeQueue.push(node)
	end

	nodesToDistance[$hostname] = 0
	$rtable.clear
	while !nodeQueue.empty?
		#now use the neighbors array to see what is min distance
		minCost = Float::INFINITY
		vertexToRemove = nil

		nodeQueue.each do |node|
			if nodesToDistance[node] <= minCost
				minCost = nodesToDistance[node]
				vertexToRemove = node
			end
		end
		nodeQueue.delete(vertexToRemove)
		# Graph info is a mapping from node name to that node's neighbor information
		# A two element array contains the node's neighbor information
		# the first element is the sequence number which Dijkstra's ignores
		# The second element is an array of Neighbor class items corresponding to that node's neighbors
		# We are iterating over vertexToRemove's neighbors, not our own.
		if($graphInfo.has_key?(vertexToRemove))
			$graphInfo[vertexToRemove].at(1).each do |othersNeighbor| 
				altDist = nodesToDistance[vertexToRemove] + othersNeighbor.cost
				if altDist < nodesToDistance[othersNeighbor.name]
					nodesToDistance[othersNeighbor.name] = altDist
					nodesToPrevious[othersNeighbor.name] = vertexToRemove
				end
			end
		end
		if(vertexToRemove != $hostname && nodesToDistance[vertexToRemove] != Float::INFINITY)
			if (nodesToPrevious[vertexToRemove] == $hostname)
				$rtable.push(RoutingInfo.new($hostname, vertexToRemove, vertexToRemove, nodesToDistance[vertexToRemove]))
				nodesToPrevious[vertexToRemove] = vertexToRemove
			else
				$rtable.push(RoutingInfo.new($hostname, vertexToRemove, nodesToPrevious[nodesToPrevious[vertexToRemove]], nodesToDistance[vertexToRemove]))
				nodesToPrevious[vertexToRemove] = vertexToRemove
			end
		end
	end
	$network_change == 0
	#puts "finished DIjkstra at #{$clock_val}"
end
	
	
# -------------- Helpers to do stuff to neighbors ----------------------- $
def handleEntryAdd(destNode, srcIP)
	clientSocket = TCPSocket.new(srcIP, $nodeToPort[destNode])
	$nodeToSocket[destNode] = clientSocket
	$rtable.push(RoutingInfo.new($hostname, destNode, destNode, 1))
	$local_change = 1
	$neighbors.push(Neighbor.new(destNode, 1))
	createOwnLSA()
end

# Handles deleting entries from the table - ASYMMETRIC
def handleEntryDelete(destNode)
	$neighbors.delete_if {|n| n.name == destNode}
	$local_change = 1
end

#Handles updating edge costs on the table
def handleEntryUpdate(destNode, newcost)
	i = $neighbors.index{|n| n.name == destNode}
	$neighbors[i].cost = newcost
	$local_change = 1
end