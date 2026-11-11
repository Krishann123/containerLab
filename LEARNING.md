Day 1
Goal: Set up codespaces with containerlab
Tried: ...
Broke: ...
Learned: From AI instructions on how to setup Codespaces, Learned from Youtube on where to find, how to install ContainerLab in Codespaces
Next: topology creation using mentioned websites

Day 2
Goal: finalizing network design.
Tried: ...
Broke: ...
Learned: From youtube, relearned how to design proper IPsec p2p vpn correctly along with encryption in transit.
Next: ...
<<<<<<< HEAD

Day 3
Goal: Setup site to site VPN tunneling and setup network topology in codespace using containers
Tried: Asked AI to generate a yaml file that has all the info/data needed for the whole network topology with the image I provided of my network topology.
Broke: ...
Learned: Basics of docker, How to use docker containers from youtube and AI. 
Next: installing and configuring rsyslog on site B

Day 4
Goal: finished up rsyslog and confirmed that setup is working properly. 
Tried: rebuilding the whole project from scratch so its easier for me to make the rebuild.sh file
Broke: ...
Learned: how to setup rsyslog, use of udp port 514 and how to route logs properly through tunnel without it being stopped by the firewall through AI gemini notebooks feature.
Next: finishing up one build command deliverable using the rebuild.sh 

Day 5
Goal: Split Site A into zones and get real firewall logs from fw-site-a into the Site B collector.
Tried: Gave the 4 PCs IPs with fw-site-a as their gateway, wrote default-deny nftables rules (App to DB on port 5432 only), then used NFLOG + ulogd so blocked and allowed traffic becomes syslog and goes through the tunnel. Tested with ping and nc and checked the FWA- lines on the collector.
Broke: After the codespace restarted the lab was gone (containers only had eth0), so zones.sh failed with "can't find device eth1". I also put fw-site-a.nft in scripts/ instead of configs/, so zones.sh couldn't find it.
Learned: The lab doesn't survive a codespace restart, so everything must live in scripts. nftables' normal log can't be read from a container, so NFLOG + ulogd is needed. The firewall never sees traffic inside one zone. Default deny needs rules in input, forward and output. (AI, then verified by running the tests in the lab)
Next: Finish the README, then the failure test (take the tunnel down and see which logs are lost).

Day 6
Goal: finalizing everything
Tried: I re-ran my commands
Broke: ended up with duplicate firewall rules and a stale tunnel peer. That is why every step now starts clean, and why rules begin with flush ruleset
Learned:...
Next: ...
