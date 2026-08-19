package main

// Seata TC 协议级探针:用官方 seata-go 的帧编解码器发 RegisterTMRequest,
// 验证 TC 完成 TM 注册握手(identified=true) —— 比"端口通"强得多的证据。
import (
	"fmt"
	"net"
	"os"
	"time"

	"github.com/seata/seata-go/pkg/protocol/codec"
	"github.com/seata/seata-go/pkg/protocol/message"
	"github.com/seata/seata-go/pkg/remoting/getty"
)

func main() {
	addr := os.Args[1]
	codec.Init()

	rpcMsg := message.RpcMessage{
		ID:         1,
		Type:       message.GettyRequestTypeRequestSync,
		Codec:      byte(codec.CodecTypeSeata),
		Compressor: 0,
		Body: message.RegisterTMRequest{AbstractIdentifyRequest: message.AbstractIdentifyRequest{
			Version:                 "2.6.0",
			ApplicationId:           "probe-app",
			TransactionServiceGroup: "default_tx_group",
		}},
	}
	h := getty.RpcPackageHandler{}
	buf, err := h.Write(nil, rpcMsg)
	if err != nil {
		fmt.Println("ENCODE_FAIL", err)
		os.Exit(1)
	}

	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		fmt.Println("DIAL_FAIL", err)
		os.Exit(1)
	}
	defer c.Close()
	fmt.Println("TCP_CONNECTED ->", c.RemoteAddr())

	c.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err = c.Write(buf); err != nil {
		fmt.Println("WRITE_FAIL", err)
		os.Exit(1)
	}
	raw := make([]byte, 2048)
	n, err := c.Read(raw)
	if err != nil {
		fmt.Println("READ_FAIL", err)
		os.Exit(1)
	}
	pkg, _, err := h.Read(nil, raw[:n])
	if err != nil {
		fmt.Printf("DECODE_FAIL %v (raw %d bytes: % x)\n", err, n, raw[:min(n, 24)])
		os.Exit(1)
	}
	rm, _ := pkg.(message.RpcMessage)
	if resp, ok := rm.Body.(message.RegisterTMResponse); ok {
		fmt.Printf("TM_REGISTER identified=%v resultCode=%v\n", resp.Identified, resp.ResultCode)
		if !resp.Identified {
			os.Exit(1)
		}
		return
	}
	fmt.Printf("TC_RESPONSE(type %T) %+v\n", rm.Body, rm.Body)
}

func min(a, b int) int { if a < b { return a }; return b }
